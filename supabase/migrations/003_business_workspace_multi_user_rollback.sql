-- Logical rollback for 003_business_workspace_multi_user.sql.
-- This restores owner-only access but intentionally keeps workspace tables,
-- columns, memberships, and rows so rollback cannot erase business data.

begin;

drop policy if exists "Business members read inventory" on public.inventory_items;
drop policy if exists "Business members insert inventory" on public.inventory_items;
drop policy if exists "Business members update inventory" on public.inventory_items;
drop policy if exists "Business members delete inventory" on public.inventory_items;
drop policy if exists "Business members read movements" on public.stock_movements;

create policy "Users manage their own inventory"
on public.inventory_items for all to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

create policy "Users read their own movements"
on public.stock_movements for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Workspace members upload inventory images" on storage.objects;
drop policy if exists "Workspace members update inventory images" on storage.objects;
drop policy if exists "Workspace members delete inventory images" on storage.objects;

create policy "Users upload their own inventory images"
on storage.objects for insert to authenticated
with check (
    bucket_id = 'inventory-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "Users update their own inventory images"
on storage.objects for update to authenticated
using (
    bucket_id = 'inventory-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
    bucket_id = 'inventory-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy "Users delete their own inventory images"
on storage.objects for delete to authenticated
using (
    bucket_id = 'inventory-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
);

revoke all on public.businesses, public.business_members, public.business_units from authenticated;
revoke execute on function public.bootstrap_ayu_owner() from authenticated;
revoke execute on function public.can_bootstrap_ayu_owner() from authenticated;
revoke execute on function public.create_business_invitation(uuid, text) from authenticated;
revoke execute on function public.accept_business_invitations() from authenticated;
revoke execute on function public.set_business_member_role(uuid, text) from authenticated;
revoke execute on function public.remove_business_member(uuid) from authenticated;
revoke execute on function public.is_business_member(uuid) from authenticated;
revoke execute on function public.is_business_owner(uuid) from authenticated;
revoke execute on function public.is_business_member_folder(text) from authenticated;

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
    where item.id = p_item_id and item.user_id = (select auth.uid())
    for update;

    if not found then
        raise exception 'Barang tidak ditemukan atau bukan milik akun ini.';
    end if;

    if p_movement_type = 'OPENING' then
        if v_item.stock_qty > 0 then
            raise exception 'Saldo awal hanya boleh dipasang pada item baru yang belum mempunyai stok.';
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
        'item_id', v_movement.item_id,
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
    where item.id = p_item_id and item.user_id = (select auth.uid())
    for update;

    if not found then
        raise exception 'Barang tidak ditemukan atau bukan milik akun ini.';
    end if;

    update public.inventory_items
    set is_active = false, archived_at = now(), archived_by = (select auth.uid()), updated_at = now()
    where id = v_item.id;

    return jsonb_build_object('id', v_item.id, 'archived_at', now(), 'is_active', false);
end;
$$;

grant execute on function public.register_stock_movement(uuid, text, numeric, text) to authenticated;
grant execute on function public.archive_item(uuid) to authenticated;

commit;