-- Run this script in Supabase SQL Editor before connecting the storefront.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    email text not null unique,
    full_name text not null default '',
    access_status text not null default 'pending'
        check (access_status in ('pending', 'approved', 'rejected')),
    is_admin boolean not null default false,
    created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.profiles
        where id = (select auth.uid())
          and is_admin = true
    );
$$;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (id, email, full_name)
    values (
        new.id,
        new.email,
        coalesce(new.raw_user_meta_data ->> 'full_name', '')
    );
    return new;
end;
$$;

drop trigger if exists create_profile_after_signup on auth.users;
create trigger create_profile_after_signup
after insert on auth.users
for each row execute function public.create_profile_for_new_user();

create table if not exists public.products (
    id uuid primary key default gen_random_uuid(),
    name text not null unique,
    price numeric(12, 2) not null check (price >= 0),
    category text not null check (category in ('Filamentos', 'Repuestos', 'Accesorios')),
    description text not null default '',
    image_url text not null,
    wholesale_enabled boolean not null default false,
    wholesale_price numeric(12, 2) check (wholesale_price is null or wholesale_price >= 0),
    wholesale_min_quantity integer check (wholesale_min_quantity is null or wholesale_min_quantity >= 2),
    on_sale boolean not null default false,
    sale_price numeric(12, 2) check (sale_price is null or sale_price >= 0),
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    constraint valid_wholesale_price check (
        (wholesale_enabled and wholesale_price is not null and wholesale_min_quantity is not null)
        or (not wholesale_enabled and wholesale_price is null and wholesale_min_quantity is null)
    ),
    constraint valid_sale_price check (
        (on_sale and sale_price is not null) or (not on_sale and sale_price is null)
    )
);

create table if not exists public.orders (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(id) on delete restrict,
    customer_name text not null,
    customer_email text not null,
    items jsonb not null check (jsonb_typeof(items) = 'array'),
    total numeric(12, 2) not null check (total >= 0),
    status text not null default 'pending'
        check (status in ('pending', 'accepted', 'rejected', 'delivered')),
    delivery_deadline timestamptz,
    rejection_reason text,
    created_at timestamptz not null default now(),
    constraint valid_order_resolution check (
        (status = 'accepted' and delivery_deadline is not null)
        or status <> 'accepted'
    ),
    constraint valid_rejection_reason check (
        (status = 'rejected' and nullif(trim(rejection_reason), '') is not null)
        or status <> 'rejected'
    )
);

create index if not exists orders_user_created_idx on public.orders (user_id, created_at desc);
create index if not exists orders_status_deadline_idx on public.orders (status, delivery_deadline);
create index if not exists profiles_status_idx on public.profiles (access_status);

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;

drop policy if exists "Users read own profile or admins read all" on public.profiles;
create policy "Users read own profile or admins read all"
on public.profiles for select to authenticated
using ((select auth.uid()) = id or (select public.is_admin()));

drop policy if exists "Admins manage profiles" on public.profiles;
create policy "Admins manage profiles"
on public.profiles for update to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

drop policy if exists "Public read active products" on public.products;
create policy "Public read active products"
on public.products for select
using (is_active or (select public.is_admin()));

drop policy if exists "Admins insert products" on public.products;
create policy "Admins insert products"
on public.products for insert to authenticated
with check ((select public.is_admin()));

drop policy if exists "Admins update products" on public.products;
create policy "Admins update products"
on public.products for update to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

drop policy if exists "Admins delete products" on public.products;
create policy "Admins delete products"
on public.products for delete to authenticated
using ((select public.is_admin()));

drop policy if exists "Customers read own orders and admins read all" on public.orders;
create policy "Customers read own orders and admins read all"
on public.orders for select to authenticated
using ((select auth.uid()) = user_id or (select public.is_admin()));

drop policy if exists "Admins update orders" on public.orders;
create policy "Admins update orders"
on public.orders for update to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

create or replace function public.create_order(order_items jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_profile public.profiles%rowtype;
    v_product public.products%rowtype;
    v_item jsonb;
    v_quantity integer;
    v_unit_price numeric(12, 2);
    v_total numeric(12, 2) := 0;
    v_saved_items jsonb := '[]'::jsonb;
    v_order_id uuid;
begin
    if v_user_id is null then
        raise exception 'Debes iniciar sesión para realizar un pedido.';
    end if;

    select * into v_profile
    from public.profiles
    where id = v_user_id and access_status = 'approved';

    if not found then
        raise exception 'La cuenta debe estar autorizada para realizar pedidos.';
    end if;

    if order_items is null
       or jsonb_typeof(order_items) is distinct from 'array'
       or jsonb_array_length(order_items) = 0 then
        raise exception 'El pedido debe incluir al menos un producto.';
    end if;

    for v_item in select value from jsonb_array_elements(order_items)
    loop
        v_quantity := (v_item ->> 'quantity')::integer;
        if v_quantity is null or v_quantity < 1 or v_quantity > 10000 then
            raise exception 'La cantidad del producto no es válida.';
        end if;

        select * into v_product
        from public.products
        where id = (v_item ->> 'product_id')::uuid and is_active = true;

        if not found then
            raise exception 'Uno de los productos ya no está disponible.';
        end if;

        if v_product.wholesale_enabled and v_quantity >= v_product.wholesale_min_quantity then
            v_unit_price := v_product.wholesale_price;
        elsif v_product.on_sale then
            v_unit_price := v_product.sale_price;
        else
            v_unit_price := v_product.price;
        end if;

        v_total := v_total + v_unit_price * v_quantity;
        v_saved_items := v_saved_items || jsonb_build_array(jsonb_build_object(
            'product_id', v_product.id,
            'product_name', v_product.name,
            'quantity', v_quantity,
            'unit_price', v_unit_price,
            'subtotal', v_unit_price * v_quantity
        ));
    end loop;

    insert into public.orders (user_id, customer_name, customer_email, items, total)
    values (
        v_user_id,
        v_profile.full_name,
        v_profile.email,
        v_saved_items,
        v_total
    )
    returning id into v_order_id;

    return v_order_id;
end;
$$;

revoke all on function public.create_order(jsonb) from public;
grant execute on function public.create_order(jsonb) to authenticated;

grant select on public.profiles to authenticated;
grant update (access_status) on public.profiles to authenticated;
grant select on public.products to anon, authenticated;
grant insert, update, delete on public.products to authenticated;
grant select, update on public.orders to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public read product images" on storage.objects;
create policy "Public read product images"
on storage.objects for select
using (bucket_id = 'product-images');

drop policy if exists "Admins upload product images" on storage.objects;
create policy "Admins upload product images"
on storage.objects for insert to authenticated
with check (bucket_id = 'product-images' and (select public.is_admin()));

drop policy if exists "Admins update product images" on storage.objects;
create policy "Admins update product images"
on storage.objects for update to authenticated
using (bucket_id = 'product-images' and (select public.is_admin()))
with check (bucket_id = 'product-images' and (select public.is_admin()));

drop policy if exists "Admins delete product images" on storage.objects;
create policy "Admins delete product images"
on storage.objects for delete to authenticated
using (bucket_id = 'product-images' and (select public.is_admin()));

insert into public.products (
    name, price, category, description, image_url,
    wholesale_enabled, wholesale_price, wholesale_min_quantity, on_sale, sale_price
) values
    ('Filamento PLA Premium 1kg', 18000, 'Filamentos', 'Alta calidad de impresión y colores vibrantes.', 'https://placehold.co/600x400/0f172a/94a3b8?text=Filamento+PLA', true, 14000, 5, true, 15500),
    ('Hotend V6 All Metal', 22000, 'Repuestos', 'Ideal para altas temperaturas.', 'https://placehold.co/600x400/0f172a/94a3b8?text=Hotend+V6', false, null, null, false, null)
on conflict (name) do nothing;

-- After creating the administrator account in Supabase Authentication, promote it:
-- update public.profiles
-- set is_admin = true, access_status = 'approved'
-- where email = 'admin@tu-dominio.com';
