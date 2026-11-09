-- Inventory workflow: atomically create an item and optional opening movement.
-- Apply after 003_business_workspace_multi_user.sql.

begin;
set local lock_timeout = '500ms';

alter table public.inventory_items
    drop constraint if exists inventory_items_business_unit_id_fkey;
alter table public.stock_movements
    drop constraint if exists stock_movements_item_id_fkey;

alter table public.stock_movements
    drop constraint if exists stock_movements_quantity_check;
alter table public.stock_movements
    add constraint stock_movements_quantity_check
    check (
        (movement_type = 'ADJUSTMENT' and quantity >= 0)
        or (movement_type <> 'ADJUSTMENT' and quantity > 0)
    );

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
     if p_movement_type is null
         or p_movement_type not in ('OPENING', 'IN', 'OUT', 'ADJUSTMENT') then
        raise exception 'Jenis perubahan stok tidak valid.';
    end if;
    if p_quantity is null or p_quantity < 0
       or (p_movement_type <> 'ADJUSTMENT' and p_quantity = 0) then
        raise exception 'Jumlah harus lebih besar dari nol, kecuali saldo akhir adjustment yang boleh nol.';
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

create or replace function public.create_inventory_item(
    p_business_id uuid,
    p_business_unit_id uuid,
    p_category text,
    p_name text,
    p_variant text default null,
    p_color text default null,
    p_sku text default null,
    p_unit text default 'pcs',
    p_initial_stock numeric default 0,
    p_min_stock numeric default 0,
    p_purchase_price numeric default 0,
    p_stem_price numeric default 0,
    p_selling_price numeric default 0,
    p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := (select auth.uid());
    v_item public.inventory_items%rowtype;
begin
    if v_user_id is null then
        raise exception 'Anda harus login untuk membuat barang.';
    end if;
    if not public.is_business_member(p_business_id) then
        raise exception 'Anda bukan anggota workspace ini.';
    end if;
    if not exists (
        select 1 from public.business_units unit
        where unit.id = p_business_unit_id
          and unit.business_id = p_business_id
    ) then
        raise exception 'Unit bisnis tidak valid untuk workspace ini.';
    end if;
    if p_category not in ('hijab', 'flower', 'tool', 'packaging', 'finished_product') then
        raise exception 'Kategori barang tidak valid.';
    end if;
    if nullif(trim(coalesce(p_name, '')), '') is null then
        raise exception 'Nama barang wajib diisi.';
    end if;
    if p_initial_stock is null or p_initial_stock < 0
       or p_min_stock is null or p_min_stock < 0
       or p_purchase_price is null or p_purchase_price < 0
       or p_stem_price is null or p_stem_price < 0
       or p_selling_price is null or p_selling_price < 0 then
        raise exception 'Stok dan harga tidak boleh negatif.';
    end if;

    insert into public.inventory_items (
        user_id, business_id, business_unit_id, created_by,
        category, name, variant, color, sku, unit, stock_qty, min_stock,
        purchase_price, stem_price, selling_price, description, is_active
    ) values (
        v_user_id, p_business_id, p_business_unit_id, v_user_id,
        p_category, trim(p_name), nullif(trim(coalesce(p_variant, '')), ''),
        nullif(trim(coalesce(p_color, '')), ''), nullif(trim(p_sku), ''),
        coalesce(nullif(trim(p_unit), ''), 'pcs'), 0, p_min_stock,
        p_purchase_price, p_stem_price, p_selling_price,
        nullif(trim(coalesce(p_description, '')), ''), true
    ) returning * into v_item;

    if p_initial_stock > 0 then
        perform public.register_stock_movement(
            v_item.id, 'OPENING', p_initial_stock, 'Saldo awal barang'
        );
        select * into v_item
        from public.inventory_items item
        where item.id = v_item.id;
    end if;

    return jsonb_build_object(
        'id', v_item.id,
        'business_id', v_item.business_id,
        'business_unit_id', v_item.business_unit_id,
        'created_by', v_item.created_by,
        'category', v_item.category,
        'name', v_item.name,
        'variant', v_item.variant,
        'color', v_item.color,
        'sku', v_item.sku,
        'unit', v_item.unit,
        'stock_qty', v_item.stock_qty,
        'min_stock', v_item.min_stock,
        'purchase_price', v_item.purchase_price,
        'stem_price', v_item.stem_price,
        'selling_price', v_item.selling_price,
        'description', v_item.description,
        'is_active', v_item.is_active,
        'created_at', v_item.created_at,
        'updated_at', v_item.updated_at
    );
end;
$$;

revoke all on function public.create_inventory_item(
    uuid, uuid, text, text, text, text, text, text, numeric, numeric,
    numeric, numeric, numeric, text
) from public, anon;
grant execute on function public.create_inventory_item(
    uuid, uuid, text, text, text, text, text, text, numeric, numeric,
    numeric, numeric, numeric, text
) to authenticated;

commit;