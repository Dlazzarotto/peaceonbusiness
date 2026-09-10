-- =====================================================================
-- PEACE ON BUSINESS â€” migration 001
-- Identidade, tenancy, grupos, entidades, papÃ©is, escopo, alÃ§ada, RLS
--
-- Projeto Supabase DEDICADO ao PoB. Rodar uma vez, em banco limpo.
-- Nada aqui depende do Peace on Tax OS: a ponte entre os dois Ã© API.
--
-- Nota de RLS: as funÃ§Ãµes auxiliares ficam no schema `app` e sÃ£o
-- SECURITY DEFINER de propÃ³sito. Ã‰ isso que evita recursÃ£o infinita nas
-- policies (uma policy de memberships que consulta memberships). NÃƒO usar
-- `force row level security` em nenhuma tabela deste arquivo, senÃ£o a
-- recursÃ£o volta.
-- =====================================================================


create extension if not exists pgcrypto;

create schema if not exists app;
revoke all on schema app from public;
grant usage on schema app to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 1. Tipos
-- ---------------------------------------------------------------------

create type public.entity_form as enum (
  'sole_prop', 'dba', 'single_llc', 'multi_llc',
  's_corp', 'c_corp', 'partnership', 'nonprofit', 'trust'
);

-- ClassificaÃ§Ã£o FISCAL Ã© confirmada pelo contador, nunca escolhida
-- livremente pelo cliente numa tela de configuraÃ§Ã£o.
create type public.tax_classification as enum (
  'schedule_c', 'disregarded', 'partnership',
  's_corp', 'c_corp', 'exempt', 'undetermined'
);

create type public.link_kind as enum ('ownership', 'management');
create type public.membership_status as enum ('invited', 'active', 'suspended', 'revoked');
create type public.accountant_access as enum ('read', 'read_adjust');
create type public.scope_kind as enum ('project', 'customer', 'location');
create type public.bank_connection_status as enum ('active', 'needs_reauth', 'disconnected');

-- ---------------------------------------------------------------------
-- 2. updated_at
-- ---------------------------------------------------------------------

create or replace function app.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 3. Grupo econÃ´mico
--    'ownership'  = participaÃ§Ã£o societÃ¡ria real (holding e filhas)
--    'management' = apenas agrupamento gerencial (empresas irmÃ£s sob
--                   dono comum, sem relaÃ§Ã£o entre as PJs)
-- ---------------------------------------------------------------------

create table public.groups (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  kind          public.link_kind not null default 'management',
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index groups_owner_idx on public.groups (owner_user_id);

create trigger groups_touch before update on public.groups
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------
-- 4. Entidade legal â€” o livro Ã© SEMPRE por entidade
-- ---------------------------------------------------------------------

create table public.entities (
  id                       uuid primary key default gen_random_uuid(),
  group_id                 uuid references public.groups(id) on delete set null,
  legal_name               text not null,
  dba_name                 text,
  form                     public.entity_form not null,
  tax_classification       public.tax_classification not null default 'undetermined',
  tax_classification_confirmed_by uuid references auth.users(id),
  tax_classification_confirmed_at timestamptz,
  formation_state          text,
  fiscal_year_end_month    smallint not null default 12
                             check (fiscal_year_end_month between 1 and 12),
  base_currency            char(3) not null default 'USD',
  -- i18n: idioma do DOCUMENTO Ã© independente do idioma da INTERFACE.
  -- O dono brasileiro opera em pt-BR e fatura o cliente dele em en-US.
  default_document_locale  text not null default 'en-US',
  is_active                boolean not null default true,
  created_by               uuid not null default auth.uid() references auth.users(id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create index entities_group_idx on public.entities (group_id);
create index entities_created_by_idx on public.entities (created_by);

create trigger entities_touch before update on public.entities
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------
-- 5. VÃ­nculo entre entidades
--    Trava real: PJ nÃ£o pode ser sÃ³cia de S-corp. Sem isso o cliente
--    desenha estrutura invÃ¡lida na tela e acha que estÃ¡ tudo certo.
-- ---------------------------------------------------------------------

create table public.entity_links (
  id                uuid primary key default gen_random_uuid(),
  parent_entity_id  uuid not null references public.entities(id) on delete cascade,
  child_entity_id   uuid not null references public.entities(id) on delete cascade,
  kind              public.link_kind not null,
  ownership_percent numeric(7,4),
  created_at        timestamptz not null default now(),
  constraint entity_links_not_self check (parent_entity_id <> child_entity_id),
  constraint entity_links_unique unique (parent_entity_id, child_entity_id)
);

create index entity_links_child_idx on public.entity_links (child_entity_id);

create or replace function app.validate_entity_link()
returns trigger
language plpgsql
security definer
set search_path = public, app
as $$
declare
  v_child_class public.tax_classification;
begin
  if new.kind = 'ownership' then
    if new.ownership_percent is null
       or new.ownership_percent <= 0
       or new.ownership_percent > 100 then
      raise exception 'VÃ­nculo societÃ¡rio exige percentual entre 0 e 100.';
    end if;

    select tax_classification into v_child_class
      from public.entities where id = new.child_entity_id;

    if v_child_class = 's_corp' then
      raise exception
        'S-corp nÃ£o pode ter pessoa jurÃ­dica como sÃ³cia. Use vÃ­nculo gerencial ou reavalie a eleiÃ§Ã£o fiscal (QSub).';
    end if;

    if exists (
      with recursive up as (
        select l.parent_entity_id as e
          from public.entity_links l
         where l.child_entity_id = new.parent_entity_id and l.kind = 'ownership'
        union
        select l.parent_entity_id
          from public.entity_links l
          join up on l.child_entity_id = up.e
         where l.kind = 'ownership'
      )
      select 1 from up where e = new.child_entity_id
    ) then
      raise exception 'VÃ­nculo societÃ¡rio criaria ciclo na estrutura.';
    end if;

  else
    if new.ownership_percent is not null then
      raise exception 'VÃ­nculo gerencial nÃ£o carrega percentual societÃ¡rio.';
    end if;
  end if;

  return new;
end $$;

create trigger entity_links_validate
  before insert or update on public.entity_links
  for each row execute function app.validate_entity_link();

-- ---------------------------------------------------------------------
-- 6. Perfil do usuÃ¡rio
-- ---------------------------------------------------------------------

create table public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  full_name        text,
  ui_locale        text not null default 'en-US',
  timezone         text not null default 'America/New_York',
  active_entity_id uuid references public.entities(id) on delete set null,
  is_accountant    boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create trigger profiles_touch before update on public.profiles
  for each row execute function app.touch_updated_at();

create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, app
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

-- ---------------------------------------------------------------------
-- 7. CatÃ¡logo de permissÃµes
-- ---------------------------------------------------------------------

create table public.permissions (
  key         text primary key,
  category    text not null,
  description text not null
);

insert into public.permissions (key, category, description) values
  ('entity.view',              'entidade',   'Ver a entidade'),
  ('entity.manage',            'entidade',   'Editar dados da entidade'),
  ('member.manage',            'equipe',     'Convidar, editar e remover membros'),
  ('role.manage',              'equipe',     'Criar e editar papÃ©is e permissÃµes'),
  ('accountant.grant',         'contador',   'Conceder e revogar acesso de contador'),
  ('coa.manage',               'razao',      'Editar o plano de contas'),
  ('journal.post',             'razao',      'Postar lanÃ§amento'),
  ('journal.adjust',           'razao',      'LanÃ§amento de ajuste contÃ¡bil'),
  ('period.close',             'razao',      'Fechar perÃ­odo'),
  ('period.reopen',            'razao',      'Reabrir perÃ­odo fechado'),
  ('ar.estimate.create',       'receber',    'Criar estimate'),
  ('ar.invoice.create',        'receber',    'Criar fatura'),
  ('ar.invoice.send',          'receber',    'Enviar fatura'),
  ('ar.payment.record',        'receber',    'Registrar recebimento'),
  ('ap.bill.create',           'pagar',      'LanÃ§ar conta a pagar'),
  ('ap.bill.approve',          'pagar',      'Aprovar conta a pagar'),
  ('ap.payment.record',        'pagar',      'Registrar pagamento'),
  ('ap.check.print',           'pagar',      'Imprimir cheque'),
  ('bank.connect',             'banco',      'Conectar e remover conta bancÃ¡ria'),
  ('bank.reconcile',           'banco',      'Conciliar extrato'),
  ('time.clock',               'ponto',      'Bater o prÃ³prio ponto'),
  ('time.approve',             'ponto',      'Aprovar e corrigir ponto da equipe'),
  ('project.view',             'projeto',    'Ver projetos no escopo'),
  ('project.manage',           'projeto',    'Criar e editar projetos'),
  ('report.financial.view',    'relatorio',  'Ver relatÃ³rios financeiros'),
  ('report.payroll.view',      'relatorio',  'Ver custo de folha'),
  ('document.branding.manage', 'documento',  'Editar marca e template dos documentos');

-- ---------------------------------------------------------------------
-- 8. PapÃ©is â€” editÃ¡veis pelo cliente, nÃ£o fixos no cÃ³digo
-- ---------------------------------------------------------------------

create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  entity_id   uuid not null references public.entities(id) on delete cascade,
  name        text not null,
  is_owner    boolean not null default false,
  is_system   boolean not null default false,
  permissions jsonb not null default '[]'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint roles_name_unique unique (entity_id, name)
);

create index roles_entity_idx on public.roles (entity_id);

create trigger roles_touch before update on public.roles
  for each row execute function app.touch_updated_at();

-- PapÃ©is de referÃªncia criados junto com a entidade. SegregaÃ§Ã£o de
-- funÃ§Ãµes embutida: quem emite fatura (Administrativo) nÃ£o registra
-- o recebimento (Tesouraria).
create or replace function app.seed_default_roles()
returns trigger
language plpgsql
security definer
set search_path = public, app
as $$
begin
  insert into public.roles (entity_id, name, is_owner, is_system, permissions) values
    (new.id, 'Dono', true, true,
      (select coalesce(jsonb_agg(key), '[]'::jsonb) from public.permissions)),
    (new.id, 'Diretoria', false, true, '[
      "entity.view","member.manage","project.view","project.manage",
      "ap.bill.approve","report.financial.view","report.payroll.view",
      "ar.invoice.create","time.approve"]'::jsonb),
    (new.id, 'Tesouraria', false, true, '[
      "entity.view","ar.payment.record","ap.bill.approve","ap.payment.record",
      "ap.check.print","bank.connect","bank.reconcile","report.financial.view"]'::jsonb),
    (new.id, 'Administrativo', false, true, '[
      "entity.view","ar.estimate.create","ar.invoice.create","ar.invoice.send",
      "ap.bill.create","project.view","time.approve"]'::jsonb),
    (new.id, 'Assistente Administrativo', false, true, '[
      "entity.view","ar.estimate.create","ap.bill.create","project.view"]'::jsonb),
    (new.id, 'Gerente de Projeto', false, true, '[
      "entity.view","project.view","project.manage","ar.estimate.create","time.approve"]'::jsonb),
    (new.id, 'FuncionÃ¡rio', false, true, '["time.clock"]'::jsonb),
    (new.id, 'Contador', false, true, '[
      "entity.view","coa.manage","journal.post","journal.adjust",
      "period.close","period.reopen","report.financial.view"]'::jsonb);

  insert into public.memberships (user_id, entity_id, role_id, status, accepted_at)
  select new.created_by, new.id, r.id, 'active', now()
    from public.roles r
   where r.entity_id = new.id and r.is_owner;

  insert into public.document_sequences (entity_id, doc_type, prefix, next_number, padding) values
    (new.id, 'estimate', 'EST-', 1000, 4),
    (new.id, 'invoice',  'INV-', 1000, 4),
    (new.id, 'bill',     'BIL-', 1000, 4),
    (new.id, 'check',    '',        1, 5),
    (new.id, 'journal',  'JE-',  1000, 4);

  return new;
end $$;

-- ---------------------------------------------------------------------
-- 9. Membership â€” vÃ­nculo pessoa <-> entidade
--    O contador Ã© a MESMA tabela, sÃ³ com outro papel. Uma pessoa em
--    vÃ¡rias empresas cai naturalmente aqui.
-- ---------------------------------------------------------------------

create table public.memberships (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  entity_id   uuid not null references public.entities(id) on delete cascade,
  role_id     uuid not null references public.roles(id) on delete restrict,
  status      public.membership_status not null default 'invited',
  -- true = enxerga sÃ³ o que estiver em membership_scopes
  scope_limited boolean not null default false,
  invited_by  uuid references auth.users(id),
  accepted_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint memberships_unique unique (user_id, entity_id)
);

create index memberships_entity_idx on public.memberships (entity_id, status);
create index memberships_user_idx on public.memberships (user_id, status);

create trigger memberships_touch before update on public.memberships
  for each row execute function app.touch_updated_at();

create trigger entities_seed_roles
  after insert on public.entities
  for each row execute function app.seed_default_roles();

-- ---------------------------------------------------------------------
-- 10. Escopo â€” o gerente do projeto A nÃ£o enxerga o projeto B
-- ---------------------------------------------------------------------

create table public.membership_scopes (
  id            uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.memberships(id) on delete cascade,
  scope_kind    public.scope_kind not null,
  scope_id      uuid not null,
  created_at    timestamptz not null default now(),
  constraint membership_scopes_unique unique (membership_id, scope_kind, scope_id)
);

create index membership_scopes_membership_idx on public.membership_scopes (membership_id);

-- ---------------------------------------------------------------------
-- 11. AlÃ§ada â€” assistente lanÃ§a atÃ© X, acima vira aprovaÃ§Ã£o
-- ---------------------------------------------------------------------

create table public.approval_limits (
  id              uuid primary key default gen_random_uuid(),
  membership_id   uuid not null references public.memberships(id) on delete cascade,
  action          text not null references public.permissions(key),
  max_amount_cents bigint not null check (max_amount_cents >= 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint approval_limits_unique unique (membership_id, action)
);

create index approval_limits_membership_idx on public.approval_limits (membership_id);

create trigger approval_limits_touch before update on public.approval_limits
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------
-- 12. Contador convidado â€” concedido pelo cliente, revogÃ¡vel
-- ---------------------------------------------------------------------

create table public.accountant_grants (
  id                  uuid primary key default gen_random_uuid(),
  entity_id           uuid not null references public.entities(id) on delete cascade,
  accountant_user_id  uuid not null references auth.users(id) on delete cascade,
  access_level        public.accountant_access not null default 'read',
  granted_by          uuid not null references auth.users(id),
  granted_at          timestamptz not null default now(),
  revoked_by          uuid references auth.users(id),
  revoked_at          timestamptz,
  constraint accountant_grants_unique unique (entity_id, accountant_user_id)
);

create index accountant_grants_user_idx
  on public.accountant_grants (accountant_user_id) where revoked_at is null;

-- ---------------------------------------------------------------------
-- 13. ConexÃµes bancÃ¡rias
--     Custo do Plaid Ã© por ITEM (um login numa instituiÃ§Ã£o) enquanto o
--     token existir, mesmo sem chamada de API. Item de cliente que
--     cancelou e nÃ£o foi removido = custo perpÃ©tuo. DaÃ­ `removed_at`
--     e a rotina mensal de reconciliaÃ§Ã£o assinatura x item ativo.
-- ---------------------------------------------------------------------

create table public.bank_connections (
  id                uuid primary key default gen_random_uuid(),
  entity_id         uuid not null references public.entities(id) on delete cascade,
  provider          text not null default 'plaid',
  provider_item_id  text not null,
  institution_id    text,
  institution_name  text,
  status            public.bank_connection_status not null default 'active',
  last_synced_at    timestamptz,
  removed_at        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint bank_connections_provider_unique unique (provider, provider_item_id)
);

-- Ãndice de cobranÃ§a: quantos itens ativos por entidade neste mÃªs.
create index bank_connections_billable_idx
  on public.bank_connections (entity_id) where removed_at is null;

create trigger bank_connections_touch before update on public.bank_connections
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------
-- 14. NumeraÃ§Ã£o â€” sequÃªncia por entidade, Ã  prova de concorrÃªncia.
--     Nunca usar max()+1: dois usuÃ¡rios simultÃ¢neos geram o mesmo
--     nÃºmero de cheque e quem liga Ã© o banco do cliente.
-- ---------------------------------------------------------------------

create table public.document_sequences (
  entity_id   uuid not null references public.entities(id) on delete cascade,
  doc_type    text not null,
  prefix      text not null default '',
  next_number bigint not null default 1 check (next_number > 0),
  padding     smallint not null default 4 check (padding between 0 and 12),
  updated_at  timestamptz not null default now(),
  primary key (entity_id, doc_type)
);

create or replace function app.next_document_number(p_entity_id uuid, p_doc_type text)
returns text
language plpgsql
security definer
set search_path = public, app
as $$
declare
  v_prefix text;
  v_num    bigint;
  v_pad    smallint;
begin
  update public.document_sequences
     set next_number = next_number + 1,
         updated_at  = now()
   where entity_id = p_entity_id
     and doc_type  = p_doc_type
  returning prefix, next_number - 1, padding
       into v_prefix, v_num, v_pad;

  if not found then
    raise exception 'SequÃªncia nÃ£o configurada: entidade % / tipo %', p_entity_id, p_doc_type;
  end if;

  return v_prefix || lpad(v_num::text, v_pad, '0');
end $$;

-- ---------------------------------------------------------------------
-- 15. Trilha de auditoria â€” sem policy de update ou delete: imutÃ¡vel
-- ---------------------------------------------------------------------

create table public.audit_log (
  id             bigserial primary key,
  entity_id      uuid references public.entities(id) on delete set null,
  actor_user_id  uuid default auth.uid() references auth.users(id),
  action         text not null,
  target_table   text,
  target_id      text,
  reason         text,
  before_state   jsonb,
  after_state    jsonb,
  created_at     timestamptz not null default now()
);

create index audit_log_entity_idx on public.audit_log (entity_id, created_at desc);

-- ---------------------------------------------------------------------
-- 16. FunÃ§Ãµes de acesso
-- ---------------------------------------------------------------------

create or replace function app.accessible_entity_ids()
returns setof uuid
language sql
security definer
stable
set search_path = public, app
as $$
  select m.entity_id
    from public.memberships m
   where m.user_id = auth.uid() and m.status = 'active'
  union
  select g.entity_id
    from public.accountant_grants g
   where g.accountant_user_id = auth.uid() and g.revoked_at is null;
$$;

create or replace function app.has_permission(p_entity_id uuid, p_permission text)
returns boolean
language sql
security definer
stable
set search_path = public, app
as $$
  select exists (
    select 1
      from public.memberships m
      join public.roles r on r.id = m.role_id
     where m.user_id = auth.uid()
       and m.entity_id = p_entity_id
       and m.status = 'active'
       and (r.is_owner or r.permissions ? p_permission)
  )
  or exists (
    select 1
      from public.accountant_grants g
     where g.accountant_user_id = auth.uid()
       and g.entity_id = p_entity_id
       and g.revoked_at is null
       and (
         p_permission in ('entity.view','report.financial.view')
         or (g.access_level = 'read_adjust'
             and p_permission in ('coa.manage','journal.post','journal.adjust',
                                  'period.close','period.reopen'))
       )
  );
$$;

-- AlÃ§ada: sem limite cadastrado, a permissÃ£o vale sem teto.
create or replace function app.within_limit(
  p_entity_id uuid, p_action text, p_amount_cents bigint
) returns boolean
language sql
security definer
stable
set search_path = public, app
as $$
  select app.has_permission(p_entity_id, p_action)
     and coalesce(
           (select p_amount_cents <= l.max_amount_cents
              from public.approval_limits l
              join public.memberships m on m.id = l.membership_id
             where m.user_id = auth.uid()
               and m.entity_id = p_entity_id
               and m.status = 'active'
               and l.action = p_action
             limit 1),
           true);
$$;

create or replace function app.in_scope(
  p_entity_id uuid, p_scope_kind public.scope_kind, p_scope_id uuid
) returns boolean
language sql
security definer
stable
set search_path = public, app
as $$
  select exists (
    select 1
      from public.memberships m
     where m.user_id = auth.uid()
       and m.entity_id = p_entity_id
       and m.status = 'active'
       and (
         not m.scope_limited
         or exists (select 1 from public.membership_scopes s
                     where s.membership_id = m.id
                       and s.scope_kind = p_scope_kind
                       and s.scope_id = p_scope_id)
       )
  );
$$;

grant execute on function
  app.accessible_entity_ids(),
  app.has_permission(uuid, text),
  app.within_limit(uuid, text, bigint),
  app.in_scope(uuid, public.scope_kind, uuid),
  app.next_document_number(uuid, text)
to authenticated;

-- ---------------------------------------------------------------------
-- 17. RLS
-- ---------------------------------------------------------------------

alter table public.groups             enable row level security;
alter table public.entities           enable row level security;
alter table public.entity_links       enable row level security;
alter table public.profiles           enable row level security;
alter table public.permissions        enable row level security;
alter table public.roles              enable row level security;
alter table public.memberships        enable row level security;
alter table public.membership_scopes  enable row level security;
alter table public.approval_limits    enable row level security;
alter table public.accountant_grants  enable row level security;
alter table public.bank_connections   enable row level security;
alter table public.document_sequences enable row level security;
alter table public.audit_log          enable row level security;

create policy permissions_read on public.permissions
  for select to authenticated using (true);

create policy profiles_self on public.profiles
  for select to authenticated
  using (id = auth.uid()
         or exists (select 1 from public.memberships m
                     where m.user_id = profiles.id
                       and m.entity_id in (select app.accessible_entity_ids())));

create policy profiles_update_self on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy groups_read on public.groups
  for select to authenticated
  using (owner_user_id = auth.uid()
         or exists (select 1 from public.entities e
                     where e.group_id = groups.id
                       and e.id in (select app.accessible_entity_ids())));

create policy groups_insert on public.groups
  for insert to authenticated with check (owner_user_id = auth.uid());

create policy groups_update on public.groups
  for update to authenticated using (owner_user_id = auth.uid());

create policy entities_read on public.entities
  for select to authenticated using (id in (select app.accessible_entity_ids()));

create policy entities_insert on public.entities
  for insert to authenticated with check (created_by = auth.uid());

create policy entities_update on public.entities
  for update to authenticated using (app.has_permission(id, 'entity.manage'));

create policy entity_links_read on public.entity_links
  for select to authenticated
  using (parent_entity_id in (select app.accessible_entity_ids())
         or child_entity_id in (select app.accessible_entity_ids()));

create policy entity_links_write on public.entity_links
  for all to authenticated
  using (app.has_permission(parent_entity_id, 'entity.manage'))
  with check (app.has_permission(parent_entity_id, 'entity.manage')
              and app.has_permission(child_entity_id, 'entity.manage'));

create policy roles_read on public.roles
  for select to authenticated using (entity_id in (select app.accessible_entity_ids()));

create policy roles_write on public.roles
  for all to authenticated
  using (app.has_permission(entity_id, 'role.manage'))
  with check (app.has_permission(entity_id, 'role.manage'));

create policy memberships_read on public.memberships
  for select to authenticated
  using (user_id = auth.uid() or entity_id in (select app.accessible_entity_ids()));

create policy memberships_write on public.memberships
  for all to authenticated
  using (app.has_permission(entity_id, 'member.manage'))
  with check (app.has_permission(entity_id, 'member.manage'));

create policy membership_scopes_read on public.membership_scopes
  for select to authenticated
  using (exists (select 1 from public.memberships m
                  where m.id = membership_scopes.membership_id
                    and (m.user_id = auth.uid()
                         or m.entity_id in (select app.accessible_entity_ids()))));

create policy membership_scopes_write on public.membership_scopes
  for all to authenticated
  using (exists (select 1 from public.memberships m
                  where m.id = membership_scopes.membership_id
                    and app.has_permission(m.entity_id, 'member.manage')))
  with check (exists (select 1 from public.memberships m
                       where m.id = membership_scopes.membership_id
                         and app.has_permission(m.entity_id, 'member.manage')));

create policy approval_limits_read on public.approval_limits
  for select to authenticated
  using (exists (select 1 from public.memberships m
                  where m.id = approval_limits.membership_id
                    and (m.user_id = auth.uid()
                         or m.entity_id in (select app.accessible_entity_ids()))));

create policy approval_limits_write on public.approval_limits
  for all to authenticated
  using (exists (select 1 from public.memberships m
                  where m.id = approval_limits.membership_id
                    and app.has_permission(m.entity_id, 'member.manage')))
  with check (exists (select 1 from public.memberships m
                       where m.id = approval_limits.membership_id
                         and app.has_permission(m.entity_id, 'member.manage')));

create policy accountant_grants_read on public.accountant_grants
  for select to authenticated
  using (accountant_user_id = auth.uid()
         or entity_id in (select app.accessible_entity_ids()));

create policy accountant_grants_write on public.accountant_grants
  for all to authenticated
  using (app.has_permission(entity_id, 'accountant.grant'))
  with check (app.has_permission(entity_id, 'accountant.grant'));

create policy bank_connections_read on public.bank_connections
  for select to authenticated using (entity_id in (select app.accessible_entity_ids()));

create policy bank_connections_write on public.bank_connections
  for all to authenticated
  using (app.has_permission(entity_id, 'bank.connect'))
  with check (app.has_permission(entity_id, 'bank.connect'));

create policy document_sequences_read on public.document_sequences
  for select to authenticated using (entity_id in (select app.accessible_entity_ids()));

create policy document_sequences_update on public.document_sequences
  for update to authenticated using (app.has_permission(entity_id, 'entity.manage'));

create policy audit_log_read on public.audit_log
  for select to authenticated using (entity_id in (select app.accessible_entity_ids()));

create policy audit_log_insert on public.audit_log
  for insert to authenticated
  with check (entity_id in (select app.accessible_entity_ids()));


-- =====================================================================
-- VerificaÃ§Ã£o pÃ³s-migration (rodar separado, deve retornar zero linhas)
--
-- Tabelas em public sem RLS ativo:
--   select tablename from pg_tables t
--    where schemaname = 'public'
--      and not exists (select 1 from pg_class c
--                       where c.relname = t.tablename and c.relrowsecurity);
--
-- Tabelas sem nenhuma policy:
--   select tablename from pg_tables t
--    where schemaname = 'public'
--      and not exists (select 1 from pg_policies p
--                       where p.tablename = t.tablename);
-- =====================================================================
