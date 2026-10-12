-- =====================================================
-- PostAngola: configuração inicial do Supabase
-- Cole tudo no SQL Editor e clique em Run (pode correr mais de uma vez).
-- =====================================================

-- 1) Perfis (um por utilizador) com papel: reader, editor ou admin
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'reader' check (role in ('reader','editor','admin')),
  created_at timestamptz not null default now()
);

-- 2) Notícias
create table if not exists public.articles (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  summary text,
  body text,
  category text not null default 'Geral',
  source_name text,
  source_url text,
  image_url text,
  status text not null default 'draft' check (status in ('draft','published')),
  featured boolean not null default false,
  published_at timestamptz,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists articles_feed_idx on public.articles (status, published_at desc);

-- 3) Funções auxiliares (security definer evita recursão nas regras)
create or replace function public.is_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('editor','admin'));
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin');
$$;

-- 4) Criar perfil automaticamente quando alguém se regista
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Perfis para contas que já existiam antes deste script
insert into public.profiles (id, full_name)
select id, split_part(email,'@',1) from auth.users
on conflict (id) do nothing;

-- 5) Segurança (RLS)
alter table public.profiles enable row level security;
alter table public.articles enable row level security;

drop policy if exists "perfil: ler o proprio" on public.profiles;
create policy "perfil: ler o proprio" on public.profiles
  for select using (id = auth.uid());

drop policy if exists "perfil: admin le todos" on public.profiles;
create policy "perfil: admin le todos" on public.profiles
  for select using (public.is_admin());

drop policy if exists "perfil: admin altera" on public.profiles;
create policy "perfil: admin altera" on public.profiles
  for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "noticias: leitura" on public.articles;
create policy "noticias: leitura" on public.articles
  for select using (status = 'published' or public.is_editor());

drop policy if exists "noticias: editores criam" on public.articles;
create policy "noticias: editores criam" on public.articles
  for insert with check (public.is_editor());

drop policy if exists "noticias: editores atualizam" on public.articles;
create policy "noticias: editores atualizam" on public.articles
  for update using (public.is_editor()) with check (public.is_editor());

drop policy if exists "noticias: editores apagam" on public.articles;
create policy "noticias: editores apagam" on public.articles
  for delete using (public.is_editor());

-- 6) Armazenamento de imagens das notícias (público para leitura)
insert into storage.buckets (id, name, public)
values ('news-images', 'news-images', true)
on conflict (id) do nothing;

drop policy if exists "imagens: leitura publica" on storage.objects;
create policy "imagens: leitura publica" on storage.objects
  for select using (bucket_id = 'news-images');

drop policy if exists "imagens: editores enviam" on storage.objects;
create policy "imagens: editores enviam" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'news-images' and public.is_editor());

drop policy if exists "imagens: editores apagam" on storage.objects;
create policy "imagens: editores apagam" on storage.objects
  for delete to authenticated
  using (bucket_id = 'news-images' and public.is_editor());

-- =====================================================
-- 7) TORNE-SE ADMIN (depois de criar a sua conta no site)
--    Troque o email pelo seu e corra só esta linha.
-- =====================================================
-- update public.profiles set role = 'admin'
-- where id = (select id from auth.users where email = 'SEU_EMAIL@exemplo.com');

-- Para dar acesso a outro editor:
-- update public.profiles set role = 'editor'
-- where id = (select id from auth.users where email = 'colega@exemplo.com');
