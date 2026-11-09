-- AYU workspace: additive multi-user inventory migration.
-- Existing inventory rows are retained and mapped to one AYU workspace.
-- Existing user accounts become STAFF; the first OWNER is provisioned separately
-- through private.business_bootstrap_grants after this migration is reviewed.

begin;

set local lock_timeout = '500ms';

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.businesses (
    id uuid primary key default gen_random_uuid(),
    slug text not null unique,
    name text not null,
    created_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists private.business_bootstrap_grants (
    user_id uuid primary key references auth.users(id) on delete cascade,
    business_id uuid not null references public.businesses(id) on delete cascade,
    business_name text not null default 'AYU BUSINESS',
    created_at timestamptz not null default now(),
    consumed_at timestamptz
);
revoke all on private.business_bootstrap_grants from public, anon, authenticated;

create table if not exists public.business_members (
    id uuid primary key default gen_random_uuid(),
    business_id uuid not null references public.businesses(id) on delete cascade,
    user_id uuid references auth.users(id) on delete cascade,
    invited_email text,
    role text not null check (role in ('OWNER', 'STAFF')),
    status text not null check (status in ('ACTIVE', 'INVITED')),
    invited_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    accepted_at timestamptz,
    constraint business_members_identity_check
        check (user_id is not null or invited_email is not null)
);

create unique index if not exists business_members_business_user_unique
    on public.business_members(business_id, user_id)
    where user_id is not null;
create unique index if not exists business_members_pending_email_unique
    on public.business_members(business_id, lower(invited_email))
    where status = 'INVITED' and invited_email is not null;
create index if not exists business_members_user_status_idx
    on public.business_members(user_id, status);

create table if not exists public.business_units (
    id uuid primary key default gen_random_uuid(),
    business_id uuid not null references public.businesses(id) on delete cascade,
    slug text not null,
    name text not null,
    is_default boolean not null default false,
    created_by uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint business_units_business_slug_unique unique (business_id, slug)
);

create unique index if not exists business_units_one_default_per_business
    on public.business_units(business_id)
    where is_default;

alter table public.inventory_items
    add column if not exists business_id uuid,
    add column if not exists business_unit_id uuid,
    add column if not exists created_by uuid references auth.users(id) on delete set null;

alter table public.stock_movements
    add column if not exists business_id uuid,
    add column if not exists actor_user_id uuid references auth.users(id) on delete set null,
    add column if not exists created_by uuid references auth.users(id) on delete set null;

insert into public.businesses (slug, name)
values ('ayu', 'AYU BUSINESS')
on conflict (slug) do nothing;

insert into public.business_units (business_id, slug, name, is_default)
select b.id, units.slug, units.name, units.is_default
from public.businesses b
cross join (values
    ('ym-thread', 'YM THREAD', false),
    ('arum-gift-buket', 'Arum Gift Buket', false),
    ('umum', 'Umum / Belum dipetakan', true)
) as units(slug, name, is_default)
where b.slug = 'ayu'
on conflict (business_id, slug) do nothing;

-- Existing account identities are preserved as active Staff memberships.
insert into public.business_members (business_id, user_id, role, status)
select b.id, legacy.user_id, 'STAFF', 'ACTIVE'
from public.businesses b
cross join (
    select user_id from public.inventory_items
    union
    select user_id from public.stock_movements
) as legacy
where b.slug = 'ayu'
on conflict do nothing;

update public.inventory_items i
set business_id = b.id,
    business_unit_id = unit.id,
    created_by = coalesce(i.created_by, i.user_id)
from public.businesses b
join public.business_units unit
  on unit.business_id = b.id
 and unit.slug = 'umum'
where b.slug = 'ayu'
  and (i.business_id is null or i.business_unit_id is null or i.created_by is null);

update public.stock_movements movement
set business_id = item.business_id,
    actor_user_id = coalesce(movement.actor_user_id, movement.user_id),
    created_by = coalesce(movement.created_by, movement.user_id)
from public.inventory_items item
where item.id = movement.item_id
  and (movement.business_id is null or movement.actor_user_id is null or movement.created_by is null);

alter table public.inventory_items
    alter column business_id set not null,
    alter column business_unit_id set not null;
alter table public.stock_movements
    alter column business_id set not null;

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.inventory_items'::regclass
          and conname = 'inventory_items_business_id_fkey'
    ) then
        alter table public.inventory_items
            add constraint inventory_items_business_id_fkey
            foreign key (business_id) references public.businesses(id) on delete restrict;
    end if;
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.inventory_items'::regclass
          and conname = 'inventory_items_business_unit_id_fkey'
    ) then
        alter table public.inventory_items
            add constraint inventory_items_business_unit_id_fkey
            foreign key (business_unit_id) references public.business_units(id) on delete restrict;
    end if;
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.stock_movements'::regclass
          and conname = 'stock_movements_business_id_fkey'
    ) then
        alter table public.stock_movements
            add constraint stock_movements_business_id_fkey
            foreign key (business_id) references public.businesses(id) on delete restrict;
    end if;
end;
$$;

create index if not exists inventory_items_business_unit_updated_idx
    on public.inventory_items(business_id, business_unit_id, updated_at desc);
create unique index if not exists inventory_items_business_id_id_unique
    on public.inventory_items(business_id, id);
create unique index if not exists business_units_business_id_id_unique
    on public.business_units(business_id, id);
create index if not exists stock_movements_business_created_idx
    on public.stock_movements(business_id, created_at desc);

do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.inventory_items'::regclass
          and conname = 'inventory_items_business_unit_workspace_fkey'
    ) then
        alter table public.inventory_items
            add constraint inventory_items_business_unit_workspace_fkey
            foreign key (business_id, business_unit_id)
            references public.business_units(business_id, id) on delete restrict;
    end if;
    if not exists (
        select 1 from pg_constraint
        where conrelid = 'public.stock_movements'::regclass
          and conname = 'stock_movements_business_item_workspace_fkey'
    ) then
        alter table public.stock_movements
            add constraint stock_movements_business_item_workspace_fkey
            foreign key (business_id, item_id)
            references public.inventory_items(business_id, id) on delete cascade;
    end if;
end;
$$;

create or replace function public.is_business_member(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.business_members member
        where member.business_id = p_business_id
          and member.user_id = (select auth.uid())
          and member.status = 'ACTIVE'
    );
$$;

create or replace function public.is_business_owner(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.business_members member
        where member.business_id = p_business_id
          and member.user_id = (select auth.uid())
          and member.role = 'OWNER'
          and member.status = 'ACTIVE'
    );
$$;

create or replace function public.is_business_member_folder(p_folder text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if (select auth.uid()) is null then
        return false;
    end if;
    if p_folder = (select auth.uid())::text then
        return true;
    end if;
    begin
        return public.is_business_member(p_folder::uuid);
    exception when invalid_text_representation then
        return false;
    end;
end;
$$;

revoke all on function public.is_business_member(uuid) from public, anon;
revoke all on function public.is_business_owner(uuid) from public, anon;
revoke all on function public.is_business_member_folder(text) from public, anon;
grant execute on function public.is_business_member(uuid) to authenticated;
grant execute on function public.is_business_owner(uuid) to authenticated;
grant execute on function public.is_business_member_folder(text) to authenticated;

create or replace function public.set_inventory_workspace()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_membership_count integer;
begin
    if (select auth.uid()) is null then
        raise exception 'Anda harus login untuk membuat barang.';
    end if;

    new.user_id := coalesce(new.user_id, (select auth.uid()));
    new.created_by := coalesce(new.created_by, (select auth.uid()));

    if new.business_id is null then
        select count(*), (array_agg(member.business_id order by member.created_at))[1]
        into v_membership_count, new.business_id
        from public.business_members member
        where member.user_id = (select auth.uid())
          and member.status = 'ACTIVE';
        if v_membership_count <> 1 then
            raise exception 'Pilih workspace yang aktif sebelum membuat barang.';
        end if;
    end if;

    if new.business_unit_id is null then
        select unit.id into new.business_unit_id
        from public.business_units unit
        where unit.business_id = new.business_id
          and unit.is_default;
    end if;

    if new.business_unit_id is null then
        raise exception 'Unit bisnis untuk barang tidak ditemukan.';
    end if;
    return new;
end;
$$;

drop trigger if exists inventory_items_set_workspace on public.inventory_items;
create trigger inventory_items_set_workspace
before insert on public.inventory_items
for each row execute function public.set_inventory_workspace();

create or replace function public.bootstrap_ayu_owner()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := (select auth.uid());
    v_business_id uuid;
    v_business_name text;
begin
    if v_user_id is null then
        raise exception 'Login diperlukan untuk bootstrap Owner.';
    end if;

    select grant_row.business_id, grant_row.business_name
    into v_business_id, v_business_name
    from private.business_bootstrap_grants grant_row
    where grant_row.user_id = v_user_id
      and grant_row.consumed_at is null
    for update;

    if v_business_id is null then
        raise exception 'Akun ini tidak memiliki grant bootstrap Owner yang aktif.';
    end if;
    if exists (
        select 1 from public.business_members member
        where member.business_id = v_business_id
          and member.role = 'OWNER'
          and member.status = 'ACTIVE'
    ) then
        raise exception 'Workspace sudah memiliki Owner aktif.';
    end if;

    update public.businesses
    set name = coalesce(nullif(trim(v_business_name), ''), name),
        created_by = v_user_id,
        updated_at = now()
    where id = v_business_id;

    insert into public.business_members (business_id, user_id, role, status, accepted_at)
    values (v_business_id, v_user_id, 'OWNER', 'ACTIVE', now())
    on conflict (business_id, user_id) where user_id is not null
    do update set role = 'OWNER', status = 'ACTIVE', accepted_at = now(), updated_at = now();

    insert into public.business_units (business_id, slug, name, is_default, created_by)
    values
        (v_business_id, 'ym-thread', 'YM THREAD', false, v_user_id),
        (v_business_id, 'arum-gift-buket', 'Arum Gift Buket', false, v_user_id),
        (v_business_id, 'umum', 'Umum / Belum dipetakan', true, v_user_id)
    on conflict (business_id, slug) do nothing;

    update private.business_bootstrap_grants
    set consumed_at = now()
    where user_id = v_user_id and business_id = v_business_id;

    return v_business_id;
end;
$$;

create or replace function public.can_bootstrap_ayu_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
        select exists (
                select 1
                from private.business_bootstrap_grants grant_row
                where grant_row.user_id = (select auth.uid())
                    and grant_row.consumed_at is null
                    and not exists (
                            select 1 from public.business_members member
                            where member.business_id = grant_row.business_id
                                and member.role = 'OWNER'
                                and member.status = 'ACTIVE'
                    )
        );
$$;
create or replace function public.create_business_invitation(p_business_id uuid, p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_email text := lower(trim(coalesce(p_email, '')));
    v_invitation_id uuid;
    v_invited_user_id uuid;
begin
    if not public.is_business_owner(p_business_id) then
        raise exception 'Hanya Owner yang dapat mengundang anggota.';
    end if;
    if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
        raise exception 'Alamat email undangan tidak valid.';
    end if;
    if lower(v_email) = lower(coalesce((select auth.jwt() ->> 'email'), '')) then
        raise exception 'Akun Owner sudah menjadi anggota workspace.';
    end if;

    select id into v_invited_user_id
    from auth.users
    where lower(email) = v_email
    limit 1;

    if v_invited_user_id is not null and exists (
        select 1 from public.business_members member
        where member.business_id = p_business_id
          and member.user_id = v_invited_user_id
          and member.status = 'ACTIVE'
    ) then
        raise exception 'Akun tersebut sudah menjadi anggota workspace.';
    end if;

    insert into public.business_members (
        business_id, user_id, invited_email, role, status, invited_by
    ) values (
        p_business_id, null, v_email, 'STAFF', 'INVITED', (select auth.uid())
    )
    on conflict (business_id, (lower(invited_email)))
        where status = 'INVITED' and invited_email is not null
    do update set invited_by = (select auth.uid()), updated_at = now()
    returning id into v_invitation_id;

    return v_invitation_id;
end;
$$;

create or replace function public.accept_business_invitations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_email text := lower(trim(coalesce((select auth.jwt() ->> 'email'), '')));
    v_count integer;
begin
    if (select auth.uid()) is null or v_email = '' then
        raise exception 'Login dengan email diperlukan untuk menerima undangan.';
    end if;
    if not exists (
        select 1 from auth.users account
        where account.id = (select auth.uid())
          and account.email_confirmed_at is not null
          and lower(account.email) = v_email
    ) then
        raise exception 'Verifikasi email akun sebelum menerima undangan.';
    end if;

    update public.business_members member
    set user_id = (select auth.uid()),
        status = 'ACTIVE',
        accepted_at = now(),
        updated_at = now()
    where member.status = 'INVITED'
      and lower(member.invited_email) = v_email
      and (member.user_id is null or member.user_id = (select auth.uid()));

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

create or replace function public.set_business_member_role(p_member_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_business_id uuid;
    v_current_role text;
    v_owner_count integer;
begin
    if upper(p_role) not in ('OWNER', 'STAFF') then
        raise exception 'Role anggota tidak valid.';
    end if;

    select member.business_id, member.role
    into v_business_id, v_current_role
    from public.business_members member
    where member.id = p_member_id and member.status = 'ACTIVE'
    for update;

    if v_business_id is null or not public.is_business_owner(v_business_id) then
        raise exception 'Hanya Owner workspace yang dapat mengatur role.';
    end if;

    if v_current_role = 'OWNER' and upper(p_role) = 'STAFF' then
        select count(*) into v_owner_count
        from public.business_members member
        where member.business_id = v_business_id
          and member.role = 'OWNER'
          and member.status = 'ACTIVE';
        if v_owner_count <= 1 then
            raise exception 'Workspace harus memiliki minimal satu Owner.';
        end if;
    end if;

    update public.business_members
    set role = upper(p_role), updated_at = now()
    where id = p_member_id;
end;
$$;

create or replace function public.remove_business_member(p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_business_id uuid;
    v_role text;
    v_owner_count integer;
begin
    select member.business_id, member.role
    into v_business_id, v_role
    from public.business_members member
    where member.id = p_member_id
    for update;

    if v_business_id is null or not public.is_business_owner(v_business_id) then
        raise exception 'Hanya Owner workspace yang dapat menghapus anggota.';
    end if;

    if v_role = 'OWNER' then
        select count(*) into v_owner_count
        from public.business_members member
        where member.business_id = v_business_id
          and member.role = 'OWNER'
          and member.status = 'ACTIVE';
        if v_owner_count <= 1 then
            raise exception 'Owner terakhir tidak dapat dihapus.';
        end if;
    end if;

    delete from public.business_members where id = p_member_id;
end;
$$;

create or replace function public.register_stock_movement(
    p_item_id uuid,
    p_movement_type text,
    p_quantity numeric,
    p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_item public.inventory_items%rowtype;
    v_new_stock numeric(12,2);
    v_movement public.stock_movements%rowtype;
begin
    if (select auth.uid()) is null then
        raise exception 'Anda harus login untuk mengubah stok.';
    end if;
    if p_movement_type not in ('OPENING', 'IN', 'OUT', 'ADJUSTMENT') then
        raise exception 'Jenis perubahan stok tidak valid.';
    end if;
    if p_quantity is null or p_quantity <= 0 then
        raise exception 'Jumlah harus lebih besar dari nol.';
    end if;

    select * into v_item
    from public.inventory_items item
    where item.id = p_item_id
      and public.is_business_member(item.business_id)
    for update;

    if not found then
        raise exception 'Barang tidak ditemukan atau bukan milik workspace Anda.';
    end if;

    if p_movement_type = 'OPENING' then
        if v_item.stock_qty > 0 then
            raise exception 'Saldo awal hanya boleh dipasang pada item tanpa stok.';
        end if;
        v_new_stock := p_quantity;
    elsif p_movement_type = 'IN' then
        v_new_stock := v_item.stock_qty + p_quantity;
    elsif p_movement_type = 'OUT' then
        v_new_stock := v_item.stock_qty - p_quantity;
    else
        v_new_stock := p_quantity;
    end if;

    if v_new_stock < 0 then
        raise exception 'Stok tidak mencukupi. Stok saat ini: %', v_item.stock_qty;
    end if;

    update public.inventory_items
    set stock_qty = v_new_stock, updated_at = now()
    where id = v_item.id;

    insert into public.stock_movements (
        user_id, business_id, actor_user_id, created_by, item_id,
        movement_type, quantity, stock_before, stock_after, note
    ) values (
        (select auth.uid()), v_item.business_id, (select auth.uid()), (select auth.uid()), v_item.id,
        p_movement_type, p_quantity, v_item.stock_qty, v_new_stock, p_note
    ) returning * into v_movement;

    return jsonb_build_object(
        'id', v_movement.id,
        'business_id', v_movement.business_id,
        'item_id', v_movement.item_id,
        'actor_user_id', v_movement.actor_user_id,
        'movement_type', v_movement.movement_type,
        'quantity', v_movement.quantity,
        'stock_before', v_movement.stock_before,
        'stock_after', v_movement.stock_after,
        'created_at', v_movement.created_at
    );
end;
$$;

create or replace function public.archive_item(p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_item public.inventory_items%rowtype;
begin
    if (select auth.uid()) is null then
        raise exception 'Anda harus login untuk mengarsipkan barang.';
    end if;

    select * into v_item
    from public.inventory_items item
    where item.id = p_item_id
      and public.is_business_member(item.business_id)
    for update;

    if not found then
        raise exception 'Barang tidak ditemukan atau bukan milik workspace Anda.';
    end if;

    update public.inventory_items
    set is_active = false, archived_at = now(), archived_by = (select auth.uid()), updated_at = now()
    where id = v_item.id;

    return jsonb_build_object('id', v_item.id, 'archived_at', now(), 'is_active', false);
end;
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists businesses_set_updated_at on public.businesses;
create trigger businesses_set_updated_at
before update on public.businesses
for each row execute function public.set_updated_at();
drop trigger if exists business_units_set_updated_at on public.business_units;
create trigger business_units_set_updated_at
before update on public.business_units
for each row execute function public.set_updated_at();
drop trigger if exists business_members_set_updated_at on public.business_members;
create trigger business_members_set_updated_at
before update on public.business_members
for each row execute function public.set_updated_at();

alter table public.businesses enable row level security;
alter table public.business_members enable row level security;
alter table public.business_units enable row level security;
alter table public.inventory_items enable row level security;
alter table public.stock_movements enable row level security;

revoke all on public.businesses, public.business_members, public.business_units from public, anon, authenticated;
revoke all on public.inventory_items, public.stock_movements from public, anon, authenticated;
grant select on public.businesses, public.business_members, public.business_units to authenticated;
grant insert (user_id, business_id, business_unit_id, category, name, variant, color, sku, unit,
              min_stock, purchase_price, stem_price, selling_price, description,
              image_url, image_path, is_active)
    on public.inventory_items to authenticated;
grant update (business_unit_id, category, name, variant, color, sku, unit, min_stock,
              purchase_price, stem_price, selling_price, description, image_url, image_path)
    on public.inventory_items to authenticated;
grant select on public.inventory_items to authenticated;
grant select on public.stock_movements to authenticated;
grant insert (business_id, slug, name, is_default) on public.business_units to authenticated;
grant update (slug, name, is_default) on public.business_units to authenticated;
grant delete on public.business_units to authenticated;

drop policy if exists "Users manage their own inventory" on public.inventory_items;
drop policy if exists "Users read their own movements" on public.stock_movements;
drop policy if exists "Business members read businesses" on public.businesses;
drop policy if exists "Business owners update businesses" on public.businesses;
drop policy if exists "Business owners manage members" on public.business_members;
drop policy if exists "Business members read units" on public.business_units;
drop policy if exists "Business owners manage units" on public.business_units;
drop policy if exists "Business members manage inventory" on public.inventory_items;
drop policy if exists "Business members read inventory" on public.inventory_items;
drop policy if exists "Business members insert inventory" on public.inventory_items;
drop policy if exists "Business members update inventory" on public.inventory_items;
drop policy if exists "Business members delete inventory" on public.inventory_items;
drop policy if exists "Business members read movements" on public.stock_movements;

create policy "Business members read businesses"
on public.businesses for select to authenticated
using (public.is_business_member(id));

create policy "Business owners update businesses"
on public.businesses for update to authenticated
using (public.is_business_owner(id))
with check (public.is_business_owner(id));
grant update (name) on public.businesses to authenticated;

create policy "Business owners manage members"
on public.business_members for select to authenticated
using (
    user_id = (select auth.uid())
    or public.is_business_owner(business_id)
    or (status = 'INVITED' and lower(invited_email) = lower((select auth.jwt() ->> 'email')))
);

create policy "Business members read units"
on public.business_units for select to authenticated
using (public.is_business_member(business_id));

create policy "Business owners manage units"
on public.business_units for all to authenticated
using (public.is_business_owner(business_id))
with check (public.is_business_owner(business_id));

create policy "Business members read inventory"
on public.inventory_items for select to authenticated
using (public.is_business_member(business_id));

create policy "Business members insert inventory"
on public.inventory_items for insert to authenticated
with check (
    public.is_business_member(business_id)
    and user_id = (select auth.uid())
    and created_by = (select auth.uid())
    and exists (
        select 1 from public.business_units unit
        where unit.id = inventory_items.business_unit_id
          and unit.business_id = inventory_items.business_id
    )
);

create policy "Business members update inventory"
on public.inventory_items for update to authenticated
using (public.is_business_member(business_id))
with check (
    public.is_business_member(business_id)
    and exists (
        select 1 from public.business_units unit
        where unit.id = inventory_items.business_unit_id
          and unit.business_id = inventory_items.business_id
    )
);

create policy "Business members read movements"
on public.stock_movements for select to authenticated
using (public.is_business_member(business_id));

revoke all on function public.register_stock_movement(uuid, text, numeric, text) from public, anon;
grant execute on function public.register_stock_movement(uuid, text, numeric, text) to authenticated;
revoke all on function public.archive_item(uuid) from public, anon;
grant execute on function public.archive_item(uuid) to authenticated;
revoke all on function public.bootstrap_ayu_owner() from public, anon;
grant execute on function public.bootstrap_ayu_owner() to authenticated;
revoke all on function public.can_bootstrap_ayu_owner() from public, anon;
grant execute on function public.can_bootstrap_ayu_owner() to authenticated;
revoke all on function public.create_business_invitation(uuid, text) from public, anon;
grant execute on function public.create_business_invitation(uuid, text) to authenticated;
revoke all on function public.accept_business_invitations() from public, anon;
grant execute on function public.accept_business_invitations() to authenticated;
revoke all on function public.set_business_member_role(uuid, text) from public, anon;
grant execute on function public.set_business_member_role(uuid, text) to authenticated;
revoke all on function public.remove_business_member(uuid) from public, anon;
grant execute on function public.remove_business_member(uuid) to authenticated;

drop policy if exists "Users upload their own inventory images" on storage.objects;
drop policy if exists "Users update their own inventory images" on storage.objects;
drop policy if exists "Users delete their own inventory images" on storage.objects;
drop policy if exists "Workspace members upload inventory images" on storage.objects;
drop policy if exists "Workspace members update inventory images" on storage.objects;
drop policy if exists "Workspace members delete inventory images" on storage.objects;

create policy "Workspace members upload inventory images"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'inventory-images'
    and public.is_business_member_folder((storage.foldername(name))[1])
);

create policy "Workspace members update inventory images"
on storage.objects for update to authenticated
using (
    bucket_id = 'inventory-images'
    and public.is_business_member_folder((storage.foldername(name))[1])
)
with check (
    bucket_id = 'inventory-images'
    and public.is_business_member_folder((storage.foldername(name))[1])
);

create policy "Workspace members delete inventory images"
on storage.objects for delete to authenticated
using (
    bucket_id = 'inventory-images'
    and public.is_business_member_folder((storage.foldername(name))[1])
);

commit;