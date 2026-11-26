-- Library Kiosk: book purchases (for the monthly income / expense page)
-- Adds one new table and one function. Existing tables and data are not changed.

create table public.purchases (
  id          bigint generated always as identity primary key,
  library_id  uuid not null references public.libraries(id) on delete cascade,
  book_id     bigint references public.books(id) on delete set null,
  book_title  text not null,                       -- kept even if the book is deleted
  qty         int not null check (qty > 0),
  unit_cost   numeric(10,2) not null check (unit_cost >= 0),
  bought_on   date not null default current_date,
  created_at  timestamptz not null default now()
);
create index on public.purchases (library_id, bought_on);
create index on public.purchases (book_id);

alter table public.purchases enable row level security;
create policy own_rows on public.purchases for all to authenticated
  using (library_id = (select public.my_library_id())) with check (library_id = (select public.my_library_id()));
grant select, delete on public.purchases to authenticated;   -- new rows only through record_purchase()

-- Record a purchase and raise the book's copy count in one step.
create or replace function public.record_purchase(p_book_id bigint, p_qty int, p_unit_cost numeric, p_date date default current_date)
returns public.purchases language plpgsql security definer set search_path = '' as $$
declare lib uuid; b public.books; r public.purchases;
begin
  select id into lib from public.libraries where owner_id = (select auth.uid());
  if lib is null then raise exception 'no library'; end if;
  if p_qty is null or p_qty < 1 then raise exception 'qty_invalid'; end if;
  if p_unit_cost is null or p_unit_cost < 0 then raise exception 'cost_invalid'; end if;
  select * into b from public.books where id = p_book_id and library_id = lib for update;
  if b.id is null then raise exception 'book_not_found'; end if;
  update public.books set copies = copies + p_qty where id = b.id;
  insert into public.purchases (library_id, book_id, book_title, qty, unit_cost, bought_on)
    values (lib, b.id, b.title, p_qty, p_unit_cost, coalesce(p_date, current_date))
    returning * into r;
  return r;
end $$;
revoke execute on function public.record_purchase(bigint,int,numeric,date) from public, anon;
grant  execute on function public.record_purchase(bigint,int,numeric,date) to authenticated;
