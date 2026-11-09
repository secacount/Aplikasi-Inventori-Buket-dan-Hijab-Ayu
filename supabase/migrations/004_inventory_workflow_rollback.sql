-- Logical rollback for 004_inventory_workflow.sql.
-- Keep the adjusted movement constraint/function because zero-balance adjustment
-- rows may already exist; do not make a data-destructive constraint rollback.

begin;

do $$
begin
    if to_regprocedure(
        'public.create_inventory_item(uuid,uuid,text,text,text,text,text,text,numeric,numeric,numeric,numeric,numeric,text)'
    ) is not null then
        execute 'revoke all on function public.create_inventory_item(uuid,uuid,text,text,text,text,text,text,numeric,numeric,numeric,numeric,numeric,text) from public, anon, authenticated';
    end if;
end;
$$;

commit;