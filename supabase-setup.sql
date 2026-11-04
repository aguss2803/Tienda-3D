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
    image_url text,
    model_url text,
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
    ),
    constraint products_has_media check (
        nullif(trim(image_url), '') is not null or nullif(trim(model_url), '') is not null
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
    delivery_date date,
    accepted_at timestamptz,
    payment_proof_path text,
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

alter table public.products add column if not exists model_url text;
alter table public.products alter column image_url drop not null;
alter table public.products drop constraint if exists products_has_media;
alter table public.products add constraint products_has_media check (
    nullif(trim(image_url), '') is not null or nullif(trim(model_url), '') is not null
);
alter table public.orders add column if not exists delivery_date date;
alter table public.orders add column if not exists accepted_at timestamptz;
alter table public.orders add column if not exists payment_proof_path text;
update public.orders
set accepted_at = created_at
where status in ('accepted', 'delivered') and accepted_at is null;
create index if not exists orders_accepted_at_idx on public.orders (accepted_at desc);
alter table public.orders drop constraint if exists valid_order_resolution;
alter table public.orders add constraint valid_order_resolution check (
    (status = 'accepted' and (delivery_date is not null or delivery_deadline is not null))
    or status <> 'accepted'
);

create table if not exists public.notifications (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(id) on delete cascade,
    order_id uuid references public.orders(id) on delete set null,
    title text not null,
    message text not null,
    read_at timestamptz,
    created_at timestamptz not null default now()
);

create index if not exists notifications_user_created_idx
    on public.notifications (user_id, created_at desc);

create table if not exists public.reviews (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(id) on delete cascade,
    author_name text not null,
    body text not null check (length(trim(body)) between 1 and 2000),
    rating integer not null check (rating between 1 and 5),
    image_url text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists reviews_created_idx on public.reviews (created_at desc);

create table if not exists public.product_conversations (
    id uuid primary key default gen_random_uuid(),
    customer_id uuid not null references public.profiles(id) on delete cascade,
    product_id uuid references public.products(id) on delete set null,
    product_name text not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (customer_id, product_id)
);

alter table public.product_conversations alter column product_id drop not null;
alter table public.product_conversations
    drop constraint if exists product_conversations_product_id_fkey;
alter table public.product_conversations
    add constraint product_conversations_product_id_fkey
    foreign key (product_id) references public.products(id) on delete set null;

create index if not exists product_conversations_updated_idx
    on public.product_conversations (updated_at desc);

create table if not exists public.product_conversation_messages (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references public.product_conversations(id) on delete cascade,
    sender_id uuid not null references public.profiles(id) on delete cascade,
    body text not null default '' check (length(trim(body)) <= 2000),
    attachment_path text,
    created_at timestamptz not null default now(),
    constraint message_has_content check (
        length(trim(body)) > 0 or attachment_path is not null
    )
);

create index if not exists product_conversation_messages_created_idx
    on public.product_conversation_messages (conversation_id, created_at);

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.notifications enable row level security;
alter table public.reviews enable row level security;
alter table public.product_conversations enable row level security;
alter table public.product_conversation_messages enable row level security;

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

drop policy if exists "Admins delete orders" on public.orders;
create policy "Admins delete orders"
on public.orders for delete to authenticated
using ((select public.is_admin()));

drop policy if exists "Users read own notifications" on public.notifications;
create policy "Users read own notifications"
on public.notifications for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Users mark own notifications read" on public.notifications;
create policy "Users mark own notifications read"
on public.notifications for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "Users delete own notifications" on public.notifications;
create policy "Users delete own notifications"
on public.notifications for delete to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Public read reviews" on public.reviews;
create policy "Public read reviews"
on public.reviews for select to anon, authenticated
using (true);

drop policy if exists "Users create own reviews" on public.reviews;
create policy "Users create own reviews"
on public.reviews for insert to authenticated
with check (
    (select auth.uid()) = user_id
    and exists (
        select 1 from public.profiles
        where id = (select auth.uid())
          and author_name = coalesce(nullif(full_name, ''), email)
    )
);

drop policy if exists "Users update own reviews or admins" on public.reviews;
create policy "Users update own reviews or admins"
on public.reviews for update to authenticated
using ((select auth.uid()) = user_id or (select public.is_admin()))
with check (
    (select public.is_admin())
    or (
        (select auth.uid()) = user_id
        and exists (
            select 1 from public.profiles
            where id = (select auth.uid())
              and author_name = coalesce(nullif(full_name, ''), email)
        )
    )
);

drop policy if exists "Users delete own reviews or admins" on public.reviews;
create policy "Users delete own reviews or admins"
on public.reviews for delete to authenticated
using ((select auth.uid()) = user_id or (select public.is_admin()));

drop policy if exists "Customers and admins read product conversations" on public.product_conversations;
create policy "Customers and admins read product conversations"
on public.product_conversations for select to authenticated
using ((select auth.uid()) = customer_id or (select public.is_admin()));

drop policy if exists "Customers start conversations for active products" on public.product_conversations;
create policy "Customers start conversations for active products"
on public.product_conversations for insert to authenticated
with check (
    (select auth.uid()) = customer_id
    and exists (
        select 1 from public.products p
        where p.id = product_conversations.product_id
          and p.is_active
          and p.name = product_conversations.product_name
    )
);

drop policy if exists "Conversation participants read messages" on public.product_conversation_messages;
create policy "Conversation participants read messages"
on public.product_conversation_messages for select to authenticated
using (
    exists (
        select 1 from public.product_conversations c
        where c.id = product_conversation_messages.conversation_id
          and (c.customer_id = (select auth.uid()) or (select public.is_admin()))
    )
);

drop policy if exists "Conversation participants send messages" on public.product_conversation_messages;
create policy "Conversation participants send messages"
on public.product_conversation_messages for insert to authenticated
with check (
    sender_id = (select auth.uid())
    and (
        attachment_path is null
        or left(
            attachment_path,
            length(conversation_id::text || '/' || (select auth.uid())::text || '/')
        ) = (conversation_id::text || '/' || (select auth.uid())::text || '/')
    )
    and exists (
        select 1 from public.product_conversations c
        where c.id = product_conversation_messages.conversation_id
          and (c.customer_id = (select auth.uid()) or (select public.is_admin()))
    )
);

create or replace function public.update_product_conversation_activity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.product_conversations
    set updated_at = now()
    where id = new.conversation_id;
    return new;
end;
$$;

drop trigger if exists update_product_conversation_activity_trigger
    on public.product_conversation_messages;
create trigger update_product_conversation_activity_trigger
after insert on public.product_conversation_messages
for each row execute function public.update_product_conversation_activity();
revoke all on function public.update_product_conversation_activity() from public, anon, authenticated;

create or replace function public.notify_product_conversation_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_customer_id uuid;
    v_product_name text;
begin
    select customer_id, product_name into v_customer_id, v_product_name
    from public.product_conversations
    where id = new.conversation_id;

    if new.sender_id = v_customer_id then
        insert into public.notifications (user_id, title, message)
        select id, 'Nuevo mensaje de cliente', 'Hay una nueva respuesta en la consulta sobre ' || v_product_name || '.'
        from public.profiles
        where is_admin and id <> new.sender_id;
    else
        insert into public.notifications (user_id, title, message)
        values (v_customer_id, 'Respuesta de AL Forge', 'El administrador respondió tu consulta sobre ' || v_product_name || '.');
    end if;
    return new;
end;
$$;

drop trigger if exists notify_product_conversation_message_trigger
    on public.product_conversation_messages;
create trigger notify_product_conversation_message_trigger
after insert on public.product_conversation_messages
for each row execute function public.notify_product_conversation_message();
revoke all on function public.notify_product_conversation_message() from public, anon, authenticated;

create or replace function public.notify_order_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_title text;
    v_message text;
begin
    if tg_op = 'INSERT' then
        insert into public.notifications (user_id, order_id, title, message)
        values (new.user_id, new.id, 'Pedido recibido', 'Recibimos tu pedido y está pendiente de revisión.');
        return new;
    end if;

    if tg_op = 'DELETE' then
        insert into public.notifications (user_id, order_id, title, message)
        values (old.user_id, null, 'Pedido eliminado', 'El administrador eliminó este pedido.');
        return old;
    end if;

    if new.status is distinct from old.status then
        if new.status = 'accepted' then
            v_title := 'Pedido aceptado';
            v_message := 'Tu pedido fue aceptado. Fecha estimada de entrega: ' ||
                to_char(coalesce(new.delivery_date, new.delivery_deadline::date), 'DD/MM/YYYY') || '.';
        elsif new.status = 'rejected' then
            v_title := 'Pedido rechazado';
            v_message := 'Tu pedido fue rechazado. Motivo: ' || coalesce(new.rejection_reason, 'No se indicó un motivo.');
        elsif new.status = 'delivered' then
            v_title := 'Pedido entregado';
            v_message := 'El administrador marcó tu pedido como entregado.';
        else
            v_title := 'Pedido actualizado';
            v_message := 'Tu pedido volvió al estado pendiente de revisión.';
        end if;

        insert into public.notifications (user_id, order_id, title, message)
        values (new.user_id, new.id, v_title, v_message);
    end if;
    return new;
end;
$$;

drop trigger if exists notify_order_changes_trigger on public.orders;
create trigger notify_order_changes_trigger
after insert or update or delete on public.orders
for each row execute function public.notify_order_changes();
revoke all on function public.notify_order_changes() from public, anon, authenticated;

create or replace function public.set_order_accepted_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if tg_op = 'INSERT' then
        if new.status in ('accepted', 'delivered') then
            new.accepted_at := now();
        else
            new.accepted_at := null;
        end if;
        return new;
    end if;

    if new.status in ('accepted', 'delivered') then
        if old.status not in ('accepted', 'delivered') then
            new.accepted_at := now();
        else
            new.accepted_at := old.accepted_at;
        end if;
    else
        new.accepted_at := null;
    end if;
    return new;
end;
$$;

drop trigger if exists set_order_accepted_at_trigger on public.orders;
create trigger set_order_accepted_at_trigger
before insert or update on public.orders
for each row execute function public.set_order_accepted_at();
revoke all on function public.set_order_accepted_at() from public, anon, authenticated;

drop function if exists public.create_order(jsonb);
drop function if exists public.create_order(jsonb, text);
create or replace function public.create_order(order_items jsonb, p_payment_proof_path text default null)
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

    if p_payment_proof_path is not null
       and split_part(p_payment_proof_path, '/', 1) <> v_user_id::text then
        raise exception 'El comprobante no pertenece a tu cuenta.';
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

    insert into public.orders (user_id, customer_name, customer_email, items, total, payment_proof_path)
    values (
        v_user_id,
        v_profile.full_name,
        v_profile.email,
        v_saved_items,
        v_total,
        p_payment_proof_path
    )
    returning id into v_order_id;

    return v_order_id;
end;
$$;

revoke all on function public.create_order(jsonb, text) from public;
grant execute on function public.create_order(jsonb, text) to authenticated;

grant select on public.profiles to authenticated;
grant update (access_status) on public.profiles to authenticated;
grant select on public.products to anon, authenticated;
grant insert, update, delete on public.products to authenticated;
grant select, update, delete on public.orders to authenticated;
grant select on public.notifications to authenticated;
grant update (read_at), delete on public.notifications to authenticated;
grant select, insert, update, delete on public.reviews to authenticated;
grant select on public.reviews to anon;
grant select, insert on public.product_conversations to authenticated;
grant select, insert on public.product_conversation_messages to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 20971520, array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'model/gltf-binary', 'model/gltf+json', 'application/octet-stream'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('community-photos', 'community-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('order-proofs', 'order-proofs', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('conversation-images', 'conversation-images', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
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

drop policy if exists "Public read community photos" on storage.objects;
create policy "Public read community photos"
on storage.objects for select
using (bucket_id = 'community-photos');

drop policy if exists "Users upload own community photos" on storage.objects;
create policy "Users upload own community photos"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'community-photos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists "Users delete own community photos or admins" on storage.objects;
create policy "Users delete own community photos or admins"
on storage.objects for delete to authenticated
using (
    bucket_id = 'community-photos'
    and ((storage.foldername(name))[1] = (select auth.uid())::text or (select public.is_admin()))
);

drop policy if exists "Users upload own order proofs" on storage.objects;
create policy "Users upload own order proofs"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'order-proofs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and exists (
        select 1 from public.profiles
        where id = (select auth.uid()) and access_status = 'approved'
    )
);

drop policy if exists "Owners and admins read order proofs" on storage.objects;
create policy "Owners and admins read order proofs"
on storage.objects for select to authenticated
using (
    bucket_id = 'order-proofs'
    and ((storage.foldername(name))[1] = (select auth.uid())::text or (select public.is_admin()))
);

drop policy if exists "Owners and admins delete order proofs" on storage.objects;
create policy "Owners and admins delete order proofs"
on storage.objects for delete to authenticated
using (
    bucket_id = 'order-proofs'
    and ((storage.foldername(name))[1] = (select auth.uid())::text or (select public.is_admin()))
);

drop policy if exists "Conversation participants read attached images" on storage.objects;
create policy "Conversation participants read attached images"
on storage.objects for select to authenticated
using (
    bucket_id = 'conversation-images'
    and exists (
        select 1 from public.product_conversations c
        where c.id::text = (storage.foldername(name))[1]
          and (c.customer_id = (select auth.uid()) or (select public.is_admin()))
    )
);

drop policy if exists "Conversation participants upload attached images" on storage.objects;
create policy "Conversation participants upload attached images"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'conversation-images'
    and (storage.foldername(name))[2] = (select auth.uid())::text
    and exists (
        select 1 from public.product_conversations c
        where c.id::text = (storage.foldername(name))[1]
          and (c.customer_id = (select auth.uid()) or (select public.is_admin()))
    )
);

drop policy if exists "Owners and admins delete attached images" on storage.objects;
create policy "Owners and admins delete attached images"
on storage.objects for delete to authenticated
using (
    bucket_id = 'conversation-images'
    and (
        (storage.foldername(name))[2] = (select auth.uid())::text
        or (select public.is_admin())
    )
    and exists (
        select 1 from public.product_conversations c
        where c.id::text = (storage.foldername(name))[1]
          and (c.customer_id = (select auth.uid()) or (select public.is_admin()))
    )
);

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
