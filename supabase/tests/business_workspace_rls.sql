-- Run only after migrations 003 and 004 have been reviewed and applied to a test project.
-- Replace the three email values below with separate, verified Supabase Auth users.
-- Execute as a single transaction in the Supabase SQL editor; all test data is rolled back.

begin;

do $$
begin
    if to_regprocedure(
        'public.create_inventory_item(uuid,uuid,text,text,text,text,text,text,numeric,numeric,numeric,numeric,numeric,text)'
    ) is null then
        raise exception 'Apply migration 004_inventory_workflow.sql before running this test.';
    end if;
end;
$$;

do $$
declare
    v_owner_email text := 'REPLACE_OWNER_EMAIL';
    v_staff_email text := 'REPLACE_STAFF_EMAIL';
    v_outsider_email text := 'REPLACE_OUTSIDER_EMAIL';
    v_owner_id uuid;
    v_staff_id uuid;
    v_outsider_id uuid;
    v_ayu_business_id uuid;
    v_other_business_id uuid;
    v_has_owner boolean;
begin
     if position('REPLACE_' in upper(v_owner_email)) > 0
         or position('REPLACE_' in upper(v_staff_email)) > 0
         or position('REPLACE_' in upper(v_outsider_email)) > 0 then
        raise exception 'Replace the three email values at the top with verified Auth user emails.';
    end if;

    select id into v_owner_id from auth.users
    where lower(email) = lower(v_owner_email) and email_confirmed_at is not null;
    select id into v_staff_id from auth.users
    where lower(email) = lower(v_staff_email) and email_confirmed_at is not null;
    select id into v_outsider_id from auth.users
    where lower(email) = lower(v_outsider_email) and email_confirmed_at is not null;

    if v_owner_id is null or v_staff_id is null or v_outsider_id is null then
        raise exception 'Each email must match a verified Supabase Auth account.';
    end if;
    if v_owner_id = v_staff_id or v_staff_id = v_outsider_id or v_owner_id = v_outsider_id then
        raise exception 'Owner, Staff, and outsider must be three different Auth accounts.';
    end if;

    select id into v_ayu_business_id
    from public.businesses where slug = 'ayu';
    if v_ayu_business_id is null then
        raise exception 'AYU workspace is missing. Confirm migration 003 completed.';
    end if;

    select exists (
        select 1 from public.business_members member
        where member.business_id = v_ayu_business_id
          and member.role = 'OWNER'
          and member.status = 'ACTIVE'
    ) into v_has_owner;

    if v_has_owner and not exists (
        select 1 from public.business_members member
        where member.business_id = v_ayu_business_id
          and member.user_id = v_owner_id
          and member.role = 'OWNER'
          and member.status = 'ACTIVE'
    ) then
        raise exception 'Selected Owner account is not the active AYU Owner. Use that Owner email for the test.';
    elsif not v_has_owner then
        insert into private.business_bootstrap_grants (user_id, business_id, business_name, consumed_at)
        values (v_owner_id, v_ayu_business_id, 'AYU BUSINESS', null)
        on conflict (user_id) do update
        set business_id = excluded.business_id,
            business_name = excluded.business_name,
            consumed_at = null;
    end if;

    insert into public.businesses (slug, name)
    values ('rls-test-' || gen_random_uuid()::text, 'RLS test workspace')
    returning id into v_other_business_id;
    insert into public.business_members (business_id, user_id, role, status, accepted_at)
    values (v_other_business_id, v_outsider_id, 'STAFF', 'ACTIVE', now());

    perform set_config('ayu_test.owner_id', v_owner_id::text, true);
    perform set_config('ayu_test.staff_id', v_staff_id::text, true);
    perform set_config('ayu_test.outsider_id', v_outsider_id::text, true);
    perform set_config('ayu_test.owner_email', v_owner_email, true);
    perform set_config('ayu_test.staff_email', v_staff_email, true);
    perform set_config('ayu_test.other_business_id', v_other_business_id::text, true);
end;
$$;

set local role authenticated;

do $$
declare
    v_owner_id uuid := current_setting('ayu_test.owner_id')::uuid;
    v_staff_id uuid := current_setting('ayu_test.staff_id')::uuid;
    v_outsider_id uuid := current_setting('ayu_test.outsider_id')::uuid;
    v_owner_email text := current_setting('ayu_test.owner_email');
    v_staff_email text := current_setting('ayu_test.staff_email');
    v_other_business_id uuid := current_setting('ayu_test.other_business_id')::uuid;
    v_business_id uuid;
    v_unit_id uuid;
    v_owner_member_id uuid;
    v_staff_member_id uuid;
    v_staff_role text;
    v_item_id uuid;
    v_created_item jsonb;
    v_visible_count integer;
    v_stock numeric(12,2);
    v_actor_id uuid;
    v_invitation_count integer;
    v_denied boolean;
begin
    if v_owner_id = v_staff_id or v_staff_id = v_outsider_id or v_owner_id = v_outsider_id then
        raise exception 'Test requires three distinct Supabase Auth users.';
    end if;

    perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object(
        'sub', v_owner_id, 'role', 'authenticated', 'email', v_owner_email
    )::text, true);

    select id into v_business_id from public.businesses where slug = 'ayu';
    if v_business_id is null or v_business_id = v_other_business_id then
        raise exception 'AYU workspace or isolation fixture is invalid.';
    end if;
    select id into v_unit_id
    from public.business_units
    where business_id = v_business_id and slug = 'ym-thread';
    select id into v_owner_member_id
    from public.business_members
    where business_id = v_business_id and user_id = v_owner_id
      and role = 'OWNER' and status = 'ACTIVE';
    select id into v_staff_member_id
    from public.business_members
    where business_id = v_business_id and user_id = v_staff_id
      and status = 'ACTIVE';

    if v_owner_member_id is null then
        perform public.bootstrap_ayu_owner();
        select id into v_owner_member_id
        from public.business_members
        where business_id = v_business_id and user_id = v_owner_id
          and role = 'OWNER' and status = 'ACTIVE';
    end if;
    if v_owner_member_id is null then
        raise exception 'Owner bootstrap did not create an active AYU Owner membership.';
    end if;
    if v_unit_id is null then
        raise exception 'YM THREAD business unit is missing. Confirm migration 003 completed.';
    end if;
    if v_staff_member_id is not null then
        select role into v_staff_role
        from public.business_members
        where id = v_staff_member_id;
        if v_staff_role = 'OWNER' then
            raise exception 'Choose a different test account for Staff; this account is already an Owner.';
        end if;
        perform public.remove_business_member(v_staff_member_id);
    end if;
    perform public.create_business_invitation(v_business_id, v_staff_email);

    perform set_config('request.jwt.claim.sub', v_staff_id::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object(
        'sub', v_staff_id, 'role', 'authenticated', 'email', v_staff_email
    )::text, true);
    v_invitation_count := public.accept_business_invitations();
    if v_invitation_count <> 1 then
        raise exception 'Staff did not accept exactly one workspace invitation.';
    end if;

    perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object(
        'sub', v_owner_id, 'role', 'authenticated', 'email', v_owner_email
    )::text, true);
    select id into v_staff_member_id
    from public.business_members
    where business_id = v_business_id and user_id = v_staff_id
      and status = 'ACTIVE';
    perform public.set_business_member_role(v_staff_member_id, 'OWNER');
    perform public.set_business_member_role(v_staff_member_id, 'STAFF');

    v_created_item := public.create_inventory_item(
        p_business_id => v_business_id,
        p_business_unit_id => v_unit_id,
        p_category => 'hijab',
        p_name => 'RLS test hijab',
        p_sku => 'RLS-' || gen_random_uuid()::text,
        p_unit => 'pcs',
        p_initial_stock => 10
    );
    v_item_id := (v_created_item ->> 'id')::uuid;

    perform set_config('request.jwt.claim.sub', v_staff_id::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object(
        'sub', v_staff_id, 'role', 'authenticated', 'email', v_staff_email
    )::text, true);
    select count(*) into v_visible_count
    from public.inventory_items where id = v_item_id;
    if v_visible_count <> 1 then
        raise exception 'Staff cannot see the Owner-created hijab.';
    end if;

    perform public.register_stock_movement(v_item_id, 'OUT', 2, 'RLS integration test');

    v_denied := false;
    begin
        perform public.set_business_member_role(v_owner_member_id, 'STAFF');
    exception when others then
        v_denied := true;
    end;
    if not v_denied then
        raise exception 'Staff unexpectedly changed the Owner role.';
    end if;

    perform set_config('request.jwt.claim.sub', v_owner_id::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object(
        'sub', v_owner_id, 'role', 'authenticated', 'email', v_owner_email
    )::text, true);
    select stock_qty into v_stock
    from public.inventory_items where id = v_item_id;
    select actor_user_id into v_actor_id
    from public.stock_movements
    where item_id = v_item_id and movement_type = 'OUT'
    order by created_at desc limit 1;
    if v_stock <> 8 or v_actor_id <> v_staff_id then
        raise exception 'Owner did not see the Staff stock-out and updated balance.';
    end if;

    perform public.register_stock_movement(v_item_id, 'ADJUSTMENT', 0, 'RLS test saldo akhir nol');
    select stock_qty into v_stock
    from public.inventory_items where id = v_item_id;
    if v_stock <> 0 then
        raise exception 'Zero-balance adjustment was not applied.';
    end if;

    perform set_config('request.jwt.claim.sub', v_outsider_id::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object(
        'sub', v_outsider_id, 'role', 'authenticated', 'email', 'outsider@example.test'
    )::text, true);
    select count(*) into v_visible_count
    from public.inventory_items where id = v_item_id;
    if v_visible_count <> 0 then
        raise exception 'A user from another workspace accessed AYU inventory.';
    end if;
end;
$$;

rollback;