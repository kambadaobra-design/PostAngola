-- =====================================================================
-- PostAngola | Equipa, níveis de acesso e fichas (RH)
-- Cole TUDO no SQL Editor do Supabase e clique em Run. Pode correr mais de uma vez.
-- Corre numa única transação: se der erro, NADA fica alterado.
--
-- NÍVEIS (código -> poder):
--   N0 Leitor | N1 Redator (envia para aprovação) | N2 Editor-chefe (publica, edita, reposta)
--   B1 Técnico de RH | B2 Diretor de RH | B10 Diretor-geral
--   M1 Administrador | M100 Super administrador | C1 Proprietário (único)
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1) Funções puras
-- ---------------------------------------------------------------------
create or replace function public.access_level(code text) returns int
language sql immutable as $$
  select case code
    when 'C1' then 200 when 'M100' then 100 when 'M1' then 90
    when 'B10' then 80 when 'B2' then 70 when 'B1' then 60
    when 'N2' then 20 when 'N1' then 10 else 0 end
$$;

create or replace function public.role_for(code text) returns text
language sql immutable as $$
  select case
    when code = 'C1' then 'ceo'
    when code in ('M1','M100') then 'admin'
    when code in ('B1','B2','B10') then 'director'
    when code = 'N2' then 'editor_chefe'
    when code = 'N1' then 'editor'
    else 'reader' end
$$;

-- ---------------------------------------------------------------------
-- 2) Limpeza: views e regras antigas (serão recriadas abaixo)
-- ---------------------------------------------------------------------
drop view if exists public.v_performance;

do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname from pg_policies
    where schemaname = 'public'
      and tablename in ('profiles','articles','employee_records','staff_invites','audit_logs','ads')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3) Perfis
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists access_code text;
alter table public.profiles add column if not exists department text;
alter table public.profiles add column if not exists rh_role text;
alter table public.profiles add column if not exists employee_category text;
alter table public.profiles add column if not exists status text;
alter table public.profiles add column if not exists approval_status text;
alter table public.profiles add column if not exists approved_by uuid;

update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email is null;

-- contas antigas: admin -> C1 (proprietário), editor -> N1
update public.profiles set access_code = case role when 'admin' then 'C1' when 'editor' then 'N1' end
 where role in ('admin','editor') and (access_code is null or access_code = 'N0');
update public.profiles set access_code = 'N0'
 where access_code is null or access_code not in ('N0','N1','N2','B1','B2','B10','M1','M100','C1');

update public.profiles set department = 'Redação' where department is null;
update public.profiles set rh_role = 'funcionario' where rh_role is null;
update public.profiles set employee_category = 'Efetivo' where employee_category is null;
update public.profiles set status = 'ativo' where status is null or status not in ('ativo','inativo');
update public.profiles set approval_status = 'aprovado'
 where approval_status is null or approval_status not in ('aprovado','pendente','rejeitado');

-- remove as restrições antigas e põe as novas
do $$
declare r record;
begin
  for r in select conname from pg_constraint where conrelid = 'public.profiles'::regclass and contype = 'c' loop
    execute format('alter table public.profiles drop constraint %I', r.conname);
  end loop;
end $$;

update public.profiles set role = public.role_for(access_code);

alter table public.profiles
  alter column access_code set default 'N0',
  alter column access_code set not null,
  alter column department set default 'Redação',
  alter column rh_role set default 'funcionario',
  alter column employee_category set default 'Efetivo',
  alter column status set default 'ativo',
  alter column status set not null,
  alter column approval_status set default 'aprovado',
  alter column approval_status set not null;

alter table public.profiles add constraint profiles_role_chk
  check (role in ('reader','editor','editor_chefe','director','admin','ceo'));
alter table public.profiles add constraint profiles_access_chk
  check (access_code in ('N0','N1','N2','B1','B2','B10','M1','M100','C1'));
alter table public.profiles add constraint profiles_status_chk
  check (status in ('ativo','inativo'));
alter table public.profiles add constraint profiles_approval_chk
  check (approval_status in ('aprovado','pendente','rejeitado'));

-- ---------------------------------------------------------------------
-- 4) Auditoria
-- ---------------------------------------------------------------------
create table if not exists public.audit_logs (
  id bigint generated by default as identity primary key,
  created_at timestamptz not null default now(),
  actor_id uuid,
  action text not null,
  target_id uuid,
  details jsonb not null default '{}'::jsonb
);
alter table public.audit_logs add column if not exists created_at timestamptz not null default now();
alter table public.audit_logs add column if not exists actor_id uuid;
alter table public.audit_logs add column if not exists action text;
alter table public.audit_logs add column if not exists target_id uuid;
alter table public.audit_logs add column if not exists details jsonb;
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='audit_logs' and column_name='details' and data_type='json') then
    alter table public.audit_logs alter column details type jsonb using details::jsonb;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 5) Fichas pessoais (dados sensíveis) em tabela à parte
-- ---------------------------------------------------------------------
create table if not exists public.employee_records (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  date_of_birth date,
  phone text,
  address text,
  nif text,
  formation text,
  contract_start date,
  contract_end date,
  notes text,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- Move os dados que já existam em "profiles" para a ficha e apaga-os de "profiles"
do $$
declare
  c text;
  have text[] := '{}';
  sel text[] := '{}';
begin
  foreach c in array array['date_of_birth','phone','address','nif','formation','contract_start','contract_end','notes'] loop
    if exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='profiles' and column_name=c) then
      have := have || c;
      if c in ('date_of_birth','contract_start','contract_end') then
        sel := sel || format('nullif(%I::text, '''')::date', c);
      else
        sel := sel || format('%I::text', c);
      end if;
    end if;
  end loop;

  if array_length(have, 1) is not null then
    execute format('insert into public.employee_records (profile_id, %s) select id, %s from public.profiles on conflict (profile_id) do nothing',
                   array_to_string(have, ','), array_to_string(sel, ','));
    foreach c in array have loop
      execute format('update public.profiles set %I = null', c);
    end loop;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 6) Convites de funcionários
-- ---------------------------------------------------------------------
create table if not exists public.staff_invites (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  full_name text not null,
  access_code text not null default 'N1',
  department text not null default 'Redação',
  employee_category text not null default 'Efetivo',
  rh_role text not null default 'funcionario',
  date_of_birth date,
  phone text,
  address text,
  nif text,
  formation text,
  contract_start date,
  notes text,
  status text not null default 'pendente' check (status in ('pendente','aprovado','aplicado','rejeitado')),
  requested_by uuid,
  approved_by uuid,
  created_at timestamptz not null default now(),
  applied_at timestamptz
);
create unique index if not exists staff_invites_open_email
  on public.staff_invites (lower(email)) where status in ('pendente','aprovado');

-- ---------------------------------------------------------------------
-- 7) Notícias: novo estado "pending" e colunas de revisão
-- ---------------------------------------------------------------------
alter table public.articles add column if not exists approved_by uuid;
alter table public.articles add column if not exists approved_at timestamptz;
alter table public.articles add column if not exists review_note text;
alter table public.articles add column if not exists image_w int;
alter table public.articles add column if not exists image_h int;
do $$
declare r record;
begin
  for r in select conname from pg_constraint
           where conrelid = 'public.articles'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format('alter table public.articles drop constraint %I', r.conname);
  end loop;
end $$;
alter table public.articles add constraint articles_status_chk
  check (status in ('draft','pending','published'));

-- ---------------------------------------------------------------------
-- 8) Funções de permissão (usadas pelas regras RLS)
-- ---------------------------------------------------------------------
create or replace function public.my_code() returns text
language sql stable security definer set search_path = public as $$
  select access_code from public.profiles
   where id = auth.uid() and status = 'ativo' and approval_status = 'aprovado'
$$;

create or replace function public.my_level() returns int
language sql stable security definer set search_path = public as $$
  select coalesce(public.access_level(public.my_code()), 0)
$$;

create or replace function public.my_dept() returns text
language sql stable security definer set search_path = public as $$
  select department from public.profiles
   where id = auth.uid() and status = 'ativo' and approval_status = 'aprovado'
$$;

create or replace function public.is_editor() returns boolean
language sql stable security definer set search_path = public as $$ select public.my_level() >= 10 $$;
create or replace function public.is_chief() returns boolean
language sql stable security definer set search_path = public as $$ select public.my_level() >= 20 $$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$ select public.my_level() >= 90 $$;

-- ver TODA a equipa: RH (B1, B2), diretor-geral e acima
create or replace function public.can_view_all_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_level() >= 80 or coalesce(public.my_code() in ('B1','B2'), false)
$$;

-- editar fichas e convidar: RH (B1, B2) e administradores
create or replace function public.can_edit_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_level() >= 90 or coalesce(public.my_code() in ('B1','B2'), false)
$$;

-- ver um perfil: o próprio, a equipa toda (RH/direção) ou, para chefias, o mesmo departamento
create or replace function public.can_view_profile(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() = target
      or public.can_view_all_staff()
      or (public.my_level() >= 20
          and (select department from public.profiles where id = target) is not distinct from public.my_dept())
$$;

-- ver os dados pessoais (NIF, morada, contacto...): o próprio e o RH/direção
create or replace function public.can_view_sensitive(target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() = target or public.can_view_all_staff()
$$;

-- ---------------------------------------------------------------------
-- 9) Regras RLS
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.employee_records enable row level security;
alter table public.staff_invites enable row level security;
alter table public.audit_logs enable row level security;
alter table public.articles enable row level security;

create policy profiles_select on public.profiles
  for select to authenticated using (public.can_view_profile(id));

create policy records_select on public.employee_records
  for select to authenticated using (public.can_view_sensitive(profile_id));

create policy invites_select on public.staff_invites
  for select to authenticated using (public.can_view_all_staff());

create policy audit_select on public.audit_logs
  for select to authenticated using ((select public.my_level()) >= 60);

create policy articles_select on public.articles
  for select using (
    status = 'published'
    or (select public.my_level()) >= 20
    or (created_by = auth.uid() and (select public.my_level()) >= 10));

create policy articles_insert on public.articles
  for insert to authenticated with check (
    created_by = auth.uid()
    and (((select public.my_level()) >= 10 and status in ('pending','draft'))
      or ((select public.my_level()) >= 20 and status = 'published')));

create policy articles_update on public.articles
  for update to authenticated
  using ((select public.my_level()) >= 20
         or (created_by = auth.uid() and status in ('pending','draft') and (select public.my_level()) >= 10))
  with check ((select public.my_level()) >= 20
         or (created_by = auth.uid() and status in ('pending','draft') and (select public.my_level()) >= 10));

create policy articles_delete on public.articles
  for delete to authenticated
  using ((select public.my_level()) >= 20
         or (created_by = auth.uid() and status in ('pending','draft') and (select public.my_level()) >= 10));

-- publicidade: só editores-chefes e acima
do $$
begin
  if to_regclass('public.ads') is not null then
    alter table public.ads enable row level security;
    create policy ads_select on public.ads
      for select using (active = true or (select public.my_level()) >= 20);
    create policy ads_insert on public.ads
      for insert to authenticated with check ((select public.my_level()) >= 20);
    create policy ads_update on public.ads
      for update to authenticated using ((select public.my_level()) >= 20) with check ((select public.my_level()) >= 20);
    create policy ads_delete on public.ads
      for delete to authenticated using ((select public.my_level()) >= 20);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 10) Convites: aplicar ao perfil quando a conta existe e o email está confirmado
-- ---------------------------------------------------------------------
create or replace function public.apply_invite(inv_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.staff_invites; uid uuid;
begin
  select * into i from public.staff_invites where id = inv_id and status = 'aprovado';
  if not found then return; end if;
  select id into uid from auth.users
   where lower(email) = lower(i.email) and email_confirmed_at is not null limit 1;
  if uid is null then return; end if;

  insert into public.profiles (id, full_name, email) values (uid, i.full_name, i.email)
    on conflict (id) do nothing;
  update public.profiles set
      access_code = i.access_code, role = public.role_for(i.access_code),
      department = i.department, employee_category = i.employee_category, rh_role = i.rh_role,
      full_name = coalesce(nullif(i.full_name, ''), full_name),
      status = 'ativo', approval_status = 'aprovado', approved_by = i.approved_by
    where id = uid;

  insert into public.employee_records
    (profile_id, date_of_birth, phone, address, nif, formation, contract_start, notes, updated_by, updated_at)
  values (uid, i.date_of_birth, i.phone, i.address, i.nif, i.formation, i.contract_start, i.notes, i.requested_by, now())
  on conflict (profile_id) do update set
      date_of_birth = coalesce(excluded.date_of_birth, public.employee_records.date_of_birth),
      phone = coalesce(excluded.phone, public.employee_records.phone),
      address = coalesce(excluded.address, public.employee_records.address),
      nif = coalesce(excluded.nif, public.employee_records.nif),
      formation = coalesce(excluded.formation, public.employee_records.formation),
      contract_start = coalesce(excluded.contract_start, public.employee_records.contract_start),
      notes = coalesce(excluded.notes, public.employee_records.notes),
      updated_by = excluded.updated_by, updated_at = now();

  update public.staff_invites set status = 'aplicado', applied_at = now() where id = inv_id;
  insert into public.audit_logs (actor_id, action, target_id, details)
    values (coalesce(auth.uid(), i.approved_by), 'invite_applied', uid,
            jsonb_build_object('email', i.email, 'code', i.access_code));
end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(new.email, '@', 1)), new.email)
  on conflict (id) do update set email = excluded.email;
  if new.email_confirmed_at is not null then
    perform public.apply_invite(i.id) from public.staff_invites i
      where lower(i.email) = lower(new.email) and i.status = 'aprovado';
  end if;
  return new;
end $$;

create or replace function public.handle_user_confirmed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.apply_invite(i.id) from public.staff_invites i
    where lower(i.email) = lower(new.email) and i.status = 'aprovado';
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed after update of email_confirmed_at on auth.users
  for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function public.handle_user_confirmed();

-- ---------------------------------------------------------------------
-- 11) Ações protegidas (RPC): é aqui que as regras de quem pode o quê são impostas
-- ---------------------------------------------------------------------
create or replace function public.invite_staff(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  a int := public.my_level();
  code text := coalesce(nullif(p->>'access_code', ''), 'N1');
  st text; new_id uuid; mail text := lower(trim(coalesce(p->>'email', '')));
begin
  if not public.can_edit_staff() then raise exception 'Sem permissão para convidar funcionários'; end if;
  if code not in ('N0','N1','N2','B1','B2','B10','M1','M100') then raise exception 'Código de acesso inválido'; end if;
  if public.access_level(code) >= a then raise exception 'Não pode atribuir um nível igual ou superior ao seu'; end if;
  if mail = '' or trim(coalesce(p->>'full_name', '')) = '' then raise exception 'Nome e email são obrigatórios'; end if;
  st := case when public.my_code() = 'C1' then 'aprovado' else 'pendente' end;
  begin
    insert into public.staff_invites
      (email, full_name, access_code, department, employee_category, rh_role,
       date_of_birth, phone, address, nif, formation, contract_start, notes, status, requested_by, approved_by)
    values
      (mail, trim(p->>'full_name'), code,
       coalesce(nullif(p->>'department', ''), 'Redação'),
       coalesce(nullif(p->>'employee_category', ''), 'Efetivo'),
       case code when 'B1' then 'tecnico_rh' when 'B2' then 'director_rh' else 'funcionario' end,
       nullif(p->>'date_of_birth', '')::date, nullif(p->>'phone', ''), nullif(p->>'address', ''),
       nullif(p->>'nif', ''), nullif(p->>'formation', ''), nullif(p->>'contract_start', '')::date,
       nullif(p->>'notes', ''), st, auth.uid(), case when st = 'aprovado' then auth.uid() end)
    returning id into new_id;
  exception when unique_violation then
    raise exception 'Já existe um convite ativo para este email';
  end;
  insert into public.audit_logs (actor_id, action, target_id, details)
    values (auth.uid(), 'invite_created', new_id, jsonb_build_object('email', mail, 'code', code, 'status', st));
  if st = 'aprovado' then perform public.apply_invite(new_id); end if;
  return new_id;
end $$;

create or replace function public.approve_invite(inv uuid, accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.my_code() is distinct from 'C1' then raise exception 'Só o proprietário (C1) aprova convites'; end if;
  if accept then
    update public.staff_invites set status = 'aprovado', approved_by = auth.uid() where id = inv and status = 'pendente';
    if not found then raise exception 'Convite não encontrado ou já tratado'; end if;
    insert into public.audit_logs (actor_id, action, target_id, details)
      values (auth.uid(), 'invite_approved', inv, '{}'::jsonb);
    perform public.apply_invite(inv);
  else
    update public.staff_invites set status = 'rejeitado', approved_by = auth.uid() where id = inv and status = 'pendente';
    if not found then raise exception 'Convite não encontrado ou já tratado'; end if;
    insert into public.audit_logs (actor_id, action, target_id, details)
      values (auth.uid(), 'invite_rejected', inv, '{}'::jsonb);
  end if;
end $$;

create or replace function public.approve_profile(target uuid, accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.my_code() is distinct from 'C1' then raise exception 'Só o proprietário (C1) aprova perfis'; end if;
  update public.profiles
     set approval_status = case when accept then 'aprovado' else 'rejeitado' end, approved_by = auth.uid()
   where id = target and approval_status = 'pendente';
  if not found then raise exception 'Perfil não encontrado ou já tratado'; end if;
  insert into public.audit_logs (actor_id, action, target_id, details)
    values (auth.uid(), case when accept then 'profile_approved' else 'profile_rejected' end, target, '{}'::jsonb);
end $$;

create or replace function public.set_access(target uuid, new_code text) returns void
language plpgsql security definer set search_path = public as $$
declare a int := public.my_level(); cur text;
begin
  if a < 90 then raise exception 'Sem permissão para alterar acessos'; end if;
  if target = auth.uid() then raise exception 'Não pode alterar o seu próprio acesso'; end if;
  if new_code not in ('N0','N1','N2','B1','B2','B10','M1','M100') then raise exception 'Código de acesso inválido'; end if;
  select access_code into cur from public.profiles where id = target;
  if cur is null then raise exception 'Perfil não encontrado'; end if;
  if public.access_level(cur) >= a then raise exception 'Não pode alterar quem tem nível igual ou superior ao seu'; end if;
  if public.access_level(new_code) >= a then raise exception 'Não pode atribuir um nível igual ou superior ao seu'; end if;
  update public.profiles set access_code = new_code, role = public.role_for(new_code) where id = target;
  insert into public.audit_logs (actor_id, action, target_id, details)
    values (auth.uid(), 'set_access', target, jsonb_build_object('from', cur, 'to', new_code));
end $$;

create or replace function public.set_status(target uuid, new_status text) returns void
language plpgsql security definer set search_path = public as $$
declare a int := public.my_level(); cur text;
begin
  if not public.can_edit_staff() then raise exception 'Sem permissão'; end if;
  if new_status not in ('ativo','inativo') then raise exception 'Estado inválido'; end if;
  if target = auth.uid() then raise exception 'Não pode alterar o estado da sua própria conta'; end if;
  select access_code into cur from public.profiles where id = target;
  if cur is null then raise exception 'Perfil não encontrado'; end if;
  if public.access_level(cur) >= a then raise exception 'Não pode alterar quem tem nível igual ou superior ao seu'; end if;
  update public.profiles set status = new_status where id = target;
  insert into public.audit_logs (actor_id, action, target_id, details)
    values (auth.uid(), 'set_status', target, jsonb_build_object('status', new_status));
end $$;

create or replace function public.staff_update(target uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare a int := public.my_level(); cur text; rh text := nullif(p->>'rh_role', '');
begin
  if not public.can_edit_staff() then raise exception 'Sem permissão para editar fichas'; end if;
  select access_code into cur from public.profiles where id = target;
  if cur is null then raise exception 'Perfil não encontrado'; end if;
  if public.access_level(cur) > a then raise exception 'Sem permissão para editar esta ficha'; end if;
  if rh is not null and rh not in ('funcionario','tecnico_rh','director_rh','ceo') then raise exception 'Função de RH inválida'; end if;

  update public.profiles set
      department = coalesce(nullif(p->>'department', ''), department),
      employee_category = coalesce(nullif(p->>'employee_category', ''), employee_category),
      rh_role = coalesce(rh, rh_role)
    where id = target;

  insert into public.employee_records
    (profile_id, date_of_birth, phone, address, nif, formation, contract_start, contract_end, notes, updated_by, updated_at)
  values (target, nullif(p->>'date_of_birth', '')::date, nullif(p->>'phone', ''), nullif(p->>'address', ''),
          nullif(p->>'nif', ''), nullif(p->>'formation', ''), nullif(p->>'contract_start', '')::date,
          nullif(p->>'contract_end', '')::date, nullif(p->>'notes', ''), auth.uid(), now())
  on conflict (profile_id) do update set
      date_of_birth = excluded.date_of_birth, phone = excluded.phone, address = excluded.address,
      nif = excluded.nif, formation = excluded.formation, contract_start = excluded.contract_start,
      contract_end = excluded.contract_end, notes = excluded.notes,
      updated_by = excluded.updated_by, updated_at = excluded.updated_at;

  insert into public.audit_logs (actor_id, action, target_id, details)
    values (auth.uid(), 'staff_updated', target, '{}'::jsonb);
end $$;

create or replace function public.log_repost(article uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t text;
begin
  if not public.is_chief() then raise exception 'Só o editor-chefe e acima podem repostar'; end if;
  select title into t from public.articles where id = article;
  insert into public.audit_logs (actor_id, action, target_id, details)
    values (auth.uid(), 'article_reposted', article, jsonb_build_object('title', t));
end $$;

-- ---------------------------------------------------------------------
-- 12) Notícias: datas, aprovação e registo automático (não pode ser falsificado)
-- ---------------------------------------------------------------------
create or replace function public.articles_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.created_by is null then new.created_by := auth.uid(); end if;
    if new.status = 'published' and new.published_at is null then new.published_at := now(); end if;
  elsif tg_op = 'UPDATE' then
    new.created_by := old.created_by;
    if old.status is distinct from 'published' and new.status = 'published' then
      new.published_at := coalesce(new.published_at, now());
      if old.status = 'pending' then new.approved_by := auth.uid(); new.approved_at := now(); end if;
    end if;
  end if;
  return new;
end $$;

create or replace function public.articles_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare act text;
begin
  if tg_op = 'INSERT' then
    act := case new.status when 'published' then 'article_published' when 'pending' then 'article_submitted' else 'article_draft' end;
    insert into public.audit_logs (actor_id, action, target_id, details)
      values (auth.uid(), act, new.id, jsonb_build_object('title', new.title));
  elsif tg_op = 'UPDATE' then
    if old.status is distinct from new.status then
      act := case
        when new.status = 'published' and old.status = 'pending' then 'article_approved'
        when new.status = 'published' then 'article_published'
        when new.status = 'draft' and old.status = 'pending' then 'article_returned'
        when new.status = 'draft' then 'article_unpublished'
        else 'article_status' end;
      insert into public.audit_logs (actor_id, action, target_id, details)
        values (auth.uid(), act, new.id, jsonb_build_object('title', new.title));
    elsif (old.title, old.summary, old.body, old.category, old.image_url, old.source_name, old.source_url)
          is distinct from (new.title, new.summary, new.body, new.category, new.image_url, new.source_name, new.source_url) then
      insert into public.audit_logs (actor_id, action, target_id, details)
        values (auth.uid(), 'article_edited', new.id,
                jsonb_build_object('title', new.title, 'status', new.status));
    elsif old.featured is distinct from new.featured then
      insert into public.audit_logs (actor_id, action, target_id, details)
        values (auth.uid(), case when new.featured then 'article_featured' else 'article_unfeatured' end, new.id,
                jsonb_build_object('title', new.title));
    end if;
  else
    insert into public.audit_logs (actor_id, action, target_id, details)
      values (auth.uid(), 'article_deleted', old.id, jsonb_build_object('title', old.title));
    return old;
  end if;
  return new;
end $$;

drop trigger if exists articles_before_trg on public.articles;
create trigger articles_before_trg before insert or update on public.articles
  for each row execute function public.articles_before();

drop trigger if exists articles_audit_trg on public.articles;
create trigger articles_audit_trg after insert or update or delete on public.articles
  for each row execute function public.articles_audit();

-- ---------------------------------------------------------------------
-- 13) Desempenho da equipa (respeita as regras de quem pode ver quem)
-- ---------------------------------------------------------------------
create view public.v_performance with (security_invoker = true) as
select
  p.id, p.full_name, p.email, p.access_code, p.role, p.department, p.employee_category,
  p.rh_role, p.status, p.approval_status,
  count(a.id) filter (where a.status = 'published'
                        and a.published_at >= date_trunc('month', now())) as news_month,
  count(a.id) filter (where a.status = 'published'
                        and a.published_at >= now() - interval '7 days') as news_week,
  count(a.id) filter (where a.status = 'published') as total_published,
  count(a.id) filter (where a.status = 'pending') as pending_approval
from public.profiles p
left join public.articles a on a.created_by = p.id
where p.access_code <> 'N0'
group by p.id;

-- ---------------------------------------------------------------------
-- 14) Permissões de tabela e de funções
-- ---------------------------------------------------------------------
revoke all on public.employee_records, public.staff_invites, public.audit_logs from anon;
revoke all on public.profiles from anon;
revoke all on public.v_performance from anon;
revoke insert, update, delete on public.profiles, public.employee_records,
                                  public.staff_invites, public.audit_logs from authenticated;
grant select on public.profiles, public.employee_records, public.staff_invites, public.audit_logs to authenticated;
grant select on public.v_performance to authenticated;

revoke all on function public.apply_invite(uuid) from public, anon, authenticated;
revoke all on function public.invite_staff(jsonb) from public, anon;
revoke all on function public.approve_invite(uuid, boolean) from public, anon;
revoke all on function public.approve_profile(uuid, boolean) from public, anon;
revoke all on function public.set_access(uuid, text) from public, anon;
revoke all on function public.set_status(uuid, text) from public, anon;
revoke all on function public.staff_update(uuid, jsonb) from public, anon;
revoke all on function public.log_repost(uuid) from public, anon;
grant execute on function public.invite_staff(jsonb) to authenticated;
grant execute on function public.approve_invite(uuid, boolean) to authenticated;
grant execute on function public.approve_profile(uuid, boolean) to authenticated;
grant execute on function public.set_access(uuid, text) to authenticated;
grant execute on function public.set_status(uuid, text) to authenticated;
grant execute on function public.staff_update(uuid, jsonb) to authenticated;
grant execute on function public.log_repost(uuid) to authenticated;

-- aviso se ninguém ficou como proprietário
do $$
begin
  if not exists (select 1 from public.profiles where access_code = 'C1') then
    raise notice 'ATENÇÃO: nenhum perfil é C1. Corra o comando "TORNAR-ME PROPRIETÁRIO" no fim deste ficheiro.';
  end if;
end $$;

commit;

-- =====================================================================
-- TORNAR-ME PROPRIETÁRIO (C1): só se o aviso acima apareceu. Troque o email e corra apenas isto:
-- =====================================================================
-- update public.profiles set access_code = 'C1', role = 'ceo'
--  where id = (select id from auth.users where email = 'SEU_EMAIL@exemplo.com');
