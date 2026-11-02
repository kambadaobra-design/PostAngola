-- =====================================================
-- 8) Publicidade: banner rotativo na capa (até 5 anúncios ativos)
-- =====================================================
create table if not exists public.ads (
  id uuid primary key default gen_random_uuid(),
  sponsor text not null,
  image_url text not null,
  image_mobile_url text,
  link_url text,
  active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.ads enable row level security;

drop policy if exists "anuncios: leitura" on public.ads;
create policy "anuncios: leitura" on public.ads
  for select using (active = true or public.is_editor());
drop policy if exists "anuncios: editores criam" on public.ads;
create policy "anuncios: editores criam" on public.ads
  for insert with check (public.is_editor());
drop policy if exists "anuncios: editores atualizam" on public.ads;
create policy "anuncios: editores atualizam" on public.ads
  for update using (public.is_editor()) with check (public.is_editor());
drop policy if exists "anuncios: editores apagam" on public.ads;
create policy "anuncios: editores apagam" on public.ads
  for delete using (public.is_editor());
