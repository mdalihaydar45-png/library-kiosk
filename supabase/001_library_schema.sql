-- Library Kiosk: initial schema (Supabase project "library", hiexfcwaepvnlantpuml)
-- One Supabase Auth user = one library owner. Every row belongs to a library,
-- and RLS lets only that library's owner read or change it.

-- ---------- tables ----------
create table public.libraries (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null unique references auth.users(id) on delete cascade,
  name        text not null,
  loan_days   int  not null default 14 check (loan_days > 0),
  max_loans   int  not null default 3  check (max_loans > 0),
  currency    text not null default '৳',
  kiosk_pin   text check (kiosk_pin ~ '^\d{4}$'),
  next_book_no int not null default 1,
  next_sale_no int not null default 1,
  created_at  timestamptz not null default now()
);

create table public.books (
  id          bigint generated always as identity primary key,
  library_id  uuid not null references public.libraries(id) on delete cascade,
  code        text not null,                       -- B0001, set by trigger
  isbn        text check (isbn ~ '^(\d{10}|\d{13})$'),
  title       text not null,
  author      text not null default '',
  category    text not null default '',
  copies      int  not null default 1 check (copies >= 0),
  price       numeric(10,2) not null default 0 check (price >= 0),
  created_at  timestamptz not null default now(),
  unique (library_id, code),
  unique (library_id, isbn)
);

create table public.members (
  id          bigint generated always as identity primary key,
  library_id  uuid not null references public.libraries(id) on delete cascade,
  name        text not null,
  phone       text not null,
  created_at  timestamptz not null default now(),
  unique (library_id, phone)
);

create table public.loans (
  id            bigint generated always as identity primary key,
  library_id    uuid not null references public.libraries(id) on delete cascade,
  book_id       bigint not null references public.books(id) on delete restrict,
  member_id     bigint not null references public.members(id) on delete restrict,
  out_date      date not null default current_date,
  due_date      date not null,
  returned_date date,
  check (due_date > out_date)
);

create table public.sales (
  id          bigint generated always as identity primary key,
  library_id  uuid not null references public.libraries(id) on delete cascade,
  book_id     bigint references public.books(id) on delete set null,
  invoice_no  text not null,
  book_title  text not null,                       -- kept even if the book is deleted
  buyer       text not null default '',
  phone       text not null default '',
  price       numeric(10,2) not null,
  method      text not null check (method in ('cash','transfer')),
  sold_on     date not null default current_date,
  unique (library_id, invoice_no)
);

create index on public.books   (library_id);
create index on public.members (library_id);
create index on public.loans   (library_id) where returned_date is null;
create index on public.loans   (book_id);
create index on public.loans   (member_id);
create index on public.sales   (library_id);
create index on public.sales   (book_id);

-- ---------- RLS ----------
create or replace function public.my_library_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.libraries where owner_id = (select auth.uid())
$$;
revoke execute on function public.my_library_id() from public, anon;
grant  execute on function public.my_library_id() to authenticated;

alter table public.libraries enable row level security;
alter table public.books     enable row level security;
alter table public.members   enable row level security;
alter table public.loans     enable row level security;
alter table public.sales     enable row level security;

create policy own_library on public.libraries for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

create policy own_rows on public.books   for all to authenticated
  using (library_id = (select public.my_library_id())) with check (library_id = (select public.my_library_id()));
create policy own_rows on public.members for all to authenticated
  using (library_id = (select public.my_library_id())) with check (library_id = (select public.my_library_id()));
create policy own_rows on public.loans   for all to authenticated
  using (library_id = (select public.my_library_id())) with check (library_id = (select public.my_library_id()));
create policy own_rows on public.sales   for select to authenticated
  using (library_id = (select public.my_library_id()));   -- sales are written only by buy_book()

-- ---------- book code B0001 ----------
create or replace function public.set_book_code()
returns trigger language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.libraries set next_book_no = next_book_no + 1
   where id = new.library_id returning next_book_no - 1 into n;
  new.code := 'B' || lpad(n::text, 4, '0');
  return new;
end $$;
revoke execute on function public.set_book_code() from public, anon, authenticated;
create trigger books_code before insert on public.books
  for each row execute function public.set_book_code();

-- ---------- kiosk actions (atomic, checks stock and limits) ----------
create or replace function public.borrow_book(p_book_id bigint, p_name text, p_phone text, p_due date)
returns public.loans language plpgsql security invoker set search_path = '' as $$
declare lib public.libraries; b public.books; m public.members; on_loan int; r public.loans;
begin
  select * into lib from public.libraries where owner_id = (select auth.uid());
  if lib.id is null then raise exception 'no library'; end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_phone),'') = '' then raise exception 'name_phone_required'; end if;
  if p_due <= current_date then raise exception 'due_in_past'; end if;
  select * into b from public.books where id = p_book_id and library_id = lib.id for update;
  if b.id is null then raise exception 'book_not_found'; end if;
  select count(*) into on_loan from public.loans where book_id = b.id and returned_date is null;
  if b.copies - on_loan < 1 then raise exception 'out_of_stock'; end if;
  insert into public.members (library_id, name, phone) values (lib.id, trim(p_name), p_phone)
    on conflict (library_id, phone) do update set phone = excluded.phone returning * into m;
  if (select count(*) from public.loans where member_id = m.id and returned_date is null) >= lib.max_loans
    then raise exception 'limit_hit'; end if;
  insert into public.loans (library_id, book_id, member_id, due_date) values (lib.id, b.id, m.id, p_due) returning * into r;
  return r;
end $$;

create or replace function public.buy_book(p_book_id bigint, p_buyer text, p_phone text, p_method text)
returns public.sales language plpgsql security definer set search_path = '' as $$
declare lib public.libraries; b public.books; on_loan int; n int; s public.sales;
begin
  select * into lib from public.libraries where owner_id = (select auth.uid()) for update;
  if lib.id is null then raise exception 'no library'; end if;
  select * into b from public.books where id = p_book_id and library_id = lib.id for update;
  if b.id is null then raise exception 'book_not_found'; end if;
  select count(*) into on_loan from public.loans where book_id = b.id and returned_date is null;
  if b.copies - on_loan < 1 then raise exception 'no_stock'; end if;
  update public.books set copies = copies - 1 where id = b.id;
  n := lib.next_sale_no;
  update public.libraries set next_sale_no = n + 1 where id = lib.id;
  insert into public.sales (library_id, book_id, invoice_no, book_title, buyer, phone, price, method)
    values (lib.id, b.id, 'INV-' || lpad(n::text, 4, '0'), b.title, coalesce(trim(p_buyer),''), coalesce(p_phone,''), b.price, p_method)
    returning * into s;
  return s;
end $$;

create or replace function public.return_loan(p_loan_id bigint)
returns boolean language sql security invoker set search_path = '' as $$
  with u as (update public.loans set returned_date = current_date
              where id = p_loan_id and returned_date is null returning 1)
  select exists (select 1 from u)
$$;

revoke execute on function public.borrow_book(bigint,text,text,date) from public, anon;
revoke execute on function public.buy_book(bigint,text,text,text)    from public, anon;
revoke execute on function public.return_loan(bigint)                from public, anon;
grant  execute on function public.borrow_book(bigint,text,text,date) to authenticated;
grant  execute on function public.buy_book(bigint,text,text,text)    to authenticated;
grant  execute on function public.return_loan(bigint)                to authenticated;

-- ---------- table privileges (new projects do not grant these by default) ----------
grant select, insert, update, delete on public.libraries, public.books, public.members, public.loans to authenticated;
grant select on public.sales to authenticated;
