-- =====================================================================
-- Egypt Trade & Investment Gateway — subscriptions backend
-- Migration 1: core schema, access control, billing, print fulfilment
-- =====================================================================
-- Tables
--   profiles, organisations, organisation_members      → who the users are
--   modules, plans, plan_modules, plan_prices          → what can be sold
--   billing_customers, subscriptions, payments         → who paid for what
--   addresses, reports, print_deliveries               → printed report fulfilment
--   report_downloads, content_events                   → usage analytics
--   newsletter_subscribers, enquiries                  → leads
--   webhook_events, audit_log                          → operations
-- Clients (the website) only ever use the anon / authenticated roles.
-- All money-related writes happen in Edge Functions with the service role.
-- =====================================================================

create extension if not exists citext with schema extensions;

-- ---------- Enums ----------------------------------------------------
create type public.plan_kind        as enum ('access', 'report', 'enterprise');
create type public.billing_interval as enum ('month', 'quarter', 'year', 'one_time');
create type public.sub_status       as enum ('incomplete', 'trialing', 'active', 'past_due', 'paused', 'canceled', 'expired', 'unpaid');
create type public.payment_status   as enum ('pending', 'succeeded', 'failed', 'refunded', 'partially_refunded');
create type public.audience_type    as enum ('uk_investor', 'uk_exporter', 'egyptian_business', 'policymaker', 'media', 'academic', 'other');
create type public.user_role        as enum ('member', 'editor', 'admin');
create type public.delivery_status  as enum ('queued', 'on_hold', 'printing', 'dispatched', 'delivered', 'returned', 'cancelled');
create type public.report_status    as enum ('draft', 'scheduled', 'published', 'archived');

-- ---------- Helpers --------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------- People ---------------------------------------------------
create table public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  email              extensions.citext,
  full_name          text,
  job_title          text,
  organisation_name  text,
  audience           public.audience_type default 'other',
  country_code       char(2),
  phone              text,
  preferred_language text not null default 'en' check (preferred_language in ('en', 'ar')),
  marketing_opt_in   boolean not null default false,
  role               public.user_role not null default 'member',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
comment on table public.profiles is 'One row per signed-up user. role=admin unlocks the admin views.';

create table public.organisations (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  country_code char(2),
  vat_number   text,
  billing_email extensions.citext,
  seat_limit   int not null default 1 check (seat_limit > 0),
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.organisation_members (
  organisation_id uuid not null references public.organisations(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  member_role     text not null default 'member' check (member_role in ('owner', 'member')),
  invited_email   extensions.citext,
  joined_at       timestamptz not null default now(),
  primary key (organisation_id, user_id)
);
create index on public.organisation_members (user_id);

-- ---------- Catalogue ------------------------------------------------
create table public.modules (
  key            text primary key,
  name_en        text not null,
  name_ar        text,
  section_anchor text,                 -- the #id of the section on the website
  is_free        boolean not null default false,
  sort_order     int not null default 0
);
comment on table public.modules is 'Content areas of the website. Locked unless is_free or granted by a plan.';

create table public.plans (
  id               uuid primary key default gen_random_uuid(),
  slug             text unique not null,
  kind             public.plan_kind not null,
  name_en          text not null,
  name_ar          text,
  tagline_en       text,
  tagline_ar       text,
  features         jsonb not null default '[]'::jsonb,   -- bullet list shown on the pricing card
  seats            int not null default 1,
  includes_pdf     boolean not null default false,        -- can download report PDFs
  report_frequency public.billing_interval,               -- report plans: how often a report is printed
  print_copies     int not null default 0,                -- copies posted per edition
  trial_days       int not null default 0,
  is_public        boolean not null default true,
  is_active        boolean not null default true,
  sort_order       int not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (kind <> 'report' or (report_frequency is not null and print_copies > 0))
);

create table public.plan_modules (
  plan_id    uuid not null references public.plans(id) on delete cascade,
  module_key text not null references public.modules(key) on delete cascade,
  primary key (plan_id, module_key)
);

create table public.plan_prices (
  id                uuid primary key default gen_random_uuid(),
  plan_id           uuid not null references public.plans(id) on delete cascade,
  billing_interval  public.billing_interval not null,
  currency          char(3) not null default 'GBP',
  amount_minor      int not null check (amount_minor >= 0),   -- pence / piastres
  tax_behavior      text not null default 'exclusive' check (tax_behavior in ('exclusive', 'inclusive')),
  provider          text not null default 'stripe',
  provider_price_id text unique,                              -- e.g. Stripe price_...
  provider_product_id text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  unique (plan_id, billing_interval, currency)
);

-- ---------- Billing --------------------------------------------------
create table public.billing_customers (
  user_id              uuid primary key references auth.users(id) on delete cascade,
  provider             text not null default 'stripe',
  provider_customer_id text unique not null,
  created_at           timestamptz not null default now()
);

create table public.addresses (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  label          text,
  recipient_name text not null,
  organisation   text,
  line1          text not null,
  line2          text,
  city           text not null,
  region         text,
  postcode       text,
  country_code   char(2) not null,
  phone          text,
  is_default     boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on public.addresses (user_id);
create unique index addresses_one_default on public.addresses (user_id) where is_default;

create table public.subscriptions (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null references auth.users(id) on delete cascade,
  organisation_id          uuid references public.organisations(id) on delete set null,
  plan_id                  uuid not null references public.plans(id),
  price_id                 uuid references public.plan_prices(id),
  status                   public.sub_status not null default 'incomplete',
  quantity                 int not null default 1,
  current_period_start     timestamptz,
  current_period_end       timestamptz,
  trial_end                timestamptz,
  cancel_at_period_end     boolean not null default false,
  canceled_at              timestamptz,
  ended_at                 timestamptz,
  shipping_address_id      uuid references public.addresses(id) on delete set null,
  provider                 text not null default 'stripe',
  provider_customer_id     text,
  provider_subscription_id text unique,
  source                   text not null default 'checkout' check (source in ('checkout', 'manual', 'invoice', 'complimentary')),
  notes                    text,
  metadata                 jsonb not null default '{}'::jsonb,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create index on public.subscriptions (user_id);
create index on public.subscriptions (organisation_id);
create index on public.subscriptions (status, current_period_end);

create table public.payments (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid references auth.users(id) on delete set null,
  subscription_id     uuid references public.subscriptions(id) on delete set null,
  amount_minor        int not null,
  tax_minor           int not null default 0,
  currency            char(3) not null,
  status              public.payment_status not null,
  provider            text not null default 'stripe',
  provider_invoice_id text unique,
  provider_payment_id text,
  invoice_number      text,
  hosted_invoice_url  text,
  invoice_pdf_url     text,
  failure_reason      text,
  period_start        timestamptz,
  period_end          timestamptz,
  paid_at             timestamptz,
  created_at          timestamptz not null default now()
);
create index on public.payments (user_id, created_at desc);
create index on public.payments (subscription_id);

-- ---------- Reports & printing --------------------------------------
create table public.reports (
  id             uuid primary key default gen_random_uuid(),
  slug           text unique not null,
  frequency      public.billing_interval not null check (frequency in ('month', 'quarter', 'year')),
  title_en       text not null,
  title_ar       text,
  summary_en     text,
  summary_ar     text,
  period_label   text not null,          -- e.g. "November 2026", "Q4 2026", "2026 Yearbook"
  period_start   date,
  period_end     date,
  page_count     int,
  pdf_path       text,                   -- object path in the private 'reports' bucket
  cover_path     text,                   -- object path in the public 'report-covers' bucket
  module_keys    text[] not null default '{}',
  status         public.report_status not null default 'draft',
  publish_at     timestamptz,
  published_at   timestamptz,
  print_run_queued_at timestamptz,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on public.reports (status, frequency, published_at desc);

create table public.print_deliveries (
  id               uuid primary key default gen_random_uuid(),
  report_id        uuid not null references public.reports(id) on delete cascade,
  subscription_id  uuid not null references public.subscriptions(id) on delete cascade,
  user_id          uuid not null references auth.users(id) on delete cascade,
  address_id       uuid references public.addresses(id) on delete set null,
  address_snapshot jsonb,                 -- frozen copy of the address at queue time
  copies           int not null default 1,
  status           public.delivery_status not null default 'queued',
  carrier          text,
  tracking_number  text,
  tracking_url     text,
  printed_at       timestamptz,
  dispatched_at    timestamptz,
  delivered_at     timestamptz,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (report_id, subscription_id)
);
create index on public.print_deliveries (status);
create index on public.print_deliveries (user_id);

create table public.report_downloads (
  id            bigint generated always as identity primary key,
  user_id       uuid references auth.users(id) on delete set null,
  report_id     uuid references public.reports(id) on delete cascade,
  downloaded_at timestamptz not null default now()
);

-- ---------- Analytics & leads ---------------------------------------
create table public.content_events (
  id          bigint generated always as identity primary key,
  user_id     uuid references auth.users(id) on delete set null,
  anon_id     text,
  event       text not null check (event in ('view', 'paywall_view', 'plan_click', 'checkout_start', 'checkout_success', 'download', 'onepager')),
  module_key  text,
  plan_slug   text,
  lang        text,
  referrer    text,
  created_at  timestamptz not null default now()
);
create index on public.content_events (event, created_at desc);
create index on public.content_events (module_key, created_at desc);

create table public.newsletter_subscribers (
  id              uuid primary key default gen_random_uuid(),
  email           extensions.citext unique not null,
  user_id         uuid references auth.users(id) on delete set null,
  source          text default 'footer',
  lang            text default 'en',
  consent_at      timestamptz not null default now(),
  unsubscribed_at timestamptz
);

create table public.enquiries (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users(id) on delete set null,
  name         text not null,
  email        extensions.citext not null,
  organisation text,
  topic        text not null default 'enterprise' check (topic in ('enterprise', 'billing', 'data', 'press', 'other')),
  seats        int,
  message      text,
  status       text not null default 'new' check (status in ('new', 'contacted', 'won', 'lost', 'closed')),
  created_at   timestamptz not null default now()
);

-- ---------- Operations -----------------------------------------------
create table public.webhook_events (
  id           text primary key,            -- provider event id → idempotency
  provider     text not null default 'stripe',
  type         text not null,
  payload      jsonb not null,
  received_at  timestamptz not null default now(),
  processed_at timestamptz,
  error        text
);

create table public.audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid,
  action     text not null,
  entity     text not null,
  entity_id  text,
  details    jsonb,
  created_at timestamptz not null default now()
);

-- ---------- updated_at triggers -------------------------------------
create trigger t_profiles_upd      before update on public.profiles      for each row execute function public.set_updated_at();
create trigger t_orgs_upd          before update on public.organisations for each row execute function public.set_updated_at();
create trigger t_plans_upd         before update on public.plans         for each row execute function public.set_updated_at();
create trigger t_addresses_upd     before update on public.addresses     for each row execute function public.set_updated_at();
create trigger t_subs_upd          before update on public.subscriptions for each row execute function public.set_updated_at();
create trigger t_reports_upd       before update on public.reports       for each row execute function public.set_updated_at();
create trigger t_deliveries_upd    before update on public.print_deliveries for each row execute function public.set_updated_at();

-- =====================================================================
-- Access functions
-- =====================================================================
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'admin');
$$;

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.role in ('admin', 'editor'));
$$;

-- Organisation ids the current user belongs to (security definer avoids RLS recursion).
create or replace function public.my_org_ids(owner_only boolean default false)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select m.organisation_id from public.organisation_members m
  where m.user_id = (select auth.uid()) and (not owner_only or m.member_role = 'owner');
$$;

-- A subscription grants access while it is active/trialing, during a 7-day
-- grace period when a renewal fails, and until the end of the paid period
-- after cancellation.
create or replace function public.subscription_grants_access(s public.subscriptions)
returns boolean language sql stable set search_path = '' as $$
  select case
    when s.status in ('active', 'trialing') then coalesce(s.current_period_end, 'infinity'::timestamptz) > now() - interval '2 days'
    when s.status = 'past_due' then coalesce(s.current_period_end, now()) > now() - interval '7 days'
    when s.status = 'canceled' then coalesce(s.current_period_end, now() - interval '1 second') > now()
    else false
  end;
$$;

-- Every subscription that reaches the given user: their own, plus any held by an organisation they belong to.
create or replace function public.user_subscriptions(uid uuid)
returns setof public.subscriptions language sql stable security definer set search_path = '' as $$
  select s.* from public.subscriptions s
  where (s.user_id = uid
         or s.organisation_id in (select m.organisation_id from public.organisation_members m where m.user_id = uid))
    and public.subscription_grants_access(s);
$$;
revoke execute on function public.user_subscriptions(uuid) from public, anon, authenticated;

create or replace function public.has_module(p_module text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.modules m where m.key = p_module and m.is_free)
      or public.is_staff()
      or exists (
        select 1 from public.user_subscriptions((select auth.uid())) s
        join public.plan_modules pm on pm.plan_id = s.plan_id
        where pm.module_key = p_module);
$$;

create or replace function public.has_report_access(p_frequency public.billing_interval default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_staff() or exists (
    select 1 from public.user_subscriptions((select auth.uid())) s
    join public.plans p on p.id = s.plan_id
    where p.includes_pdf
       or (p.kind = 'report' and (p_frequency is null or p.report_frequency = p_frequency)));
$$;

-- One call the website makes after sign-in: everything it needs to unlock the page.
create or replace function public.my_access()
returns jsonb language sql stable security definer set search_path = '' as $$
  with me as (select (select auth.uid()) as uid),
  subs as (select s.* from me, public.user_subscriptions(me.uid) s)
  select jsonb_build_object(
    'signed_in', (select uid from me) is not null,
    'is_staff',  public.is_staff(),
    'modules', coalesce((
        select jsonb_agg(distinct k) from (
          select m.key as k from public.modules m where m.is_free or public.is_staff()
          union
          select pm.module_key from subs join public.plan_modules pm on pm.plan_id = subs.plan_id
        ) x), '[]'::jsonb),
    'pdf', public.has_report_access(null),
    'subscriptions', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', s.id, 'plan', p.slug, 'kind', p.kind, 'name', p.name_en, 'name_ar', p.name_ar,
          'status', s.status, 'interval', pp.billing_interval,
          'amount_minor', pp.amount_minor, 'currency', pp.currency,
          'current_period_end', s.current_period_end, 'cancel_at_period_end', s.cancel_at_period_end,
          'via_organisation', s.user_id <> (select uid from me)) order by p.sort_order)
        from subs s join public.plans p on p.id = s.plan_id left join public.plan_prices pp on pp.id = s.price_id),
      '[]'::jsonb)
  );
$$;

-- Public pricing feed for the website (plans + prices + modules in one call).
create or replace view public.pricing_catalogue with (security_invoker = true) as
select p.id, p.slug, p.kind, p.name_en, p.name_ar, p.tagline_en, p.tagline_ar, p.features,
       p.seats, p.includes_pdf, p.report_frequency, p.print_copies, p.trial_days, p.sort_order,
       coalesce((select jsonb_agg(pm.module_key order by pm.module_key) from public.plan_modules pm where pm.plan_id = p.id), '[]'::jsonb) as modules,
       coalesce((select jsonb_agg(jsonb_build_object('id', pp.id, 'interval', pp.billing_interval, 'currency', pp.currency, 'amount_minor', pp.amount_minor)
                                  order by pp.billing_interval)
                 from public.plan_prices pp where pp.plan_id = p.id and pp.is_active), '[]'::jsonb) as prices
from public.plans p
where p.is_active and p.is_public;

-- =====================================================================
-- New user → profile; protect privileged columns
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare md jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, email, full_name, organisation_name, job_title, audience, country_code, preferred_language, marketing_opt_in)
  values (
    new.id, new.email,
    nullif(md->>'full_name', ''), nullif(md->>'organisation', ''), nullif(md->>'job_title', ''),
    case when md->>'audience' in ('uk_investor','uk_exporter','egyptian_business','policymaker','media','academic','other')
         then (md->>'audience')::public.audience_type else 'other' end,
    nullif(upper(left(md->>'country_code', 2)), ''),
    case when md->>'lang' = 'ar' then 'ar' else 'en' end,
    coalesce((md->>'marketing_opt_in')::boolean, false))
  on conflict (id) do nothing;

  if coalesce((md->>'marketing_opt_in')::boolean, false) then
    insert into public.newsletter_subscribers (email, user_id, source, lang)
    values (new.email, new.id, 'signup', case when md->>'lang' = 'ar' then 'ar' else 'en' end)
    on conflict (email) do update set user_id = excluded.user_id, unsubscribed_at = null;
  end if;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- Keep profile email in step with auth email changes.
create or replace function public.handle_user_email_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = new.email where id = new.id;
  end if;
  return new;
end $$;
create trigger on_auth_user_email_changed
  after update of email on auth.users for each row execute function public.handle_user_email_change();

-- Members cannot promote themselves to admin/editor.
create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.role is distinct from old.role
     and auth.uid() is not null            -- SQL editor / service role have no user id
     and not public.is_admin() then
    raise exception 'Only an admin can change roles';
  end if;
  return new;
end $$;
create trigger t_guard_profile_role before update on public.profiles for each row execute function public.guard_profile_role();

-- =====================================================================
-- Print fulfilment
-- =====================================================================
-- Queue one delivery per eligible report subscription when a report is published.
create or replace function public.queue_print_run(p_report uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare r public.reports; n int;
begin
  select * into r from public.reports where id = p_report;
  if r.id is null then raise exception 'Report not found'; end if;
  if auth.uid() is not null and not public.is_staff() then
    raise exception 'Not allowed';
  end if;

  insert into public.print_deliveries (report_id, subscription_id, user_id, address_id, address_snapshot, copies, status)
  select r.id, s.id, s.user_id, a.id,
         case when a.id is null then null else jsonb_build_object(
           'recipient_name', a.recipient_name, 'organisation', a.organisation, 'line1', a.line1, 'line2', a.line2,
           'city', a.city, 'region', a.region, 'postcode', a.postcode, 'country_code', a.country_code, 'phone', a.phone) end,
         p.print_copies * s.quantity,
         case when a.id is null then 'on_hold'::public.delivery_status else 'queued'::public.delivery_status end
  from public.subscriptions s
  join public.plans p on p.id = s.plan_id
  left join lateral (
    select * from public.addresses ad
    where ad.id = s.shipping_address_id or (s.shipping_address_id is null and ad.user_id = s.user_id and ad.is_default)
    order by (ad.id = s.shipping_address_id) desc limit 1) a on true
  where p.kind = 'report'
    and p.report_frequency = r.frequency
    and s.status in ('active', 'trialing')
    and coalesce(s.current_period_end, 'infinity'::timestamptz) > now()
  on conflict (report_id, subscription_id) do nothing;
  get diagnostics n = row_count;

  update public.reports set print_run_queued_at = now() where id = r.id;
  insert into public.audit_log (actor_id, action, entity, entity_id, details)
  values (auth.uid(), 'print_run_queued', 'report', r.id::text, jsonb_build_object('deliveries', n));
  return n;
end $$;
revoke execute on function public.queue_print_run(uuid) from public, anon;

create or replace function public.on_report_published()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published') then
    new.published_at := coalesce(new.published_at, now());
  end if;
  return new;
end $$;
create trigger t_report_publish_stamp before insert or update of status on public.reports
  for each row execute function public.on_report_published();

create or replace function public.after_report_published()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'published' and new.print_run_queued_at is null then
    perform public.queue_print_run(new.id);
  end if;
  return null;
end $$;
create trigger t_report_publish_queue after insert or update of status on public.reports
  for each row execute function public.after_report_published();

-- A subscriber who adds an address later releases their on-hold deliveries.
create or replace function public.release_on_hold_deliveries()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.is_default then
    update public.print_deliveries d
       set address_id = new.id, status = 'queued',
           address_snapshot = jsonb_build_object('recipient_name', new.recipient_name, 'organisation', new.organisation,
             'line1', new.line1, 'line2', new.line2, 'city', new.city, 'region', new.region,
             'postcode', new.postcode, 'country_code', new.country_code, 'phone', new.phone)
     where d.user_id = new.user_id and d.status = 'on_hold';
  end if;
  return null;
end $$;
create trigger t_release_on_hold after insert or update on public.addresses
  for each row execute function public.release_on_hold_deliveries();

-- Housekeeping: mark subscriptions that have run out (covers manual/invoiced ones that no webhook will close).
create or replace function public.expire_lapsed_subscriptions()
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.subscriptions
     set status = 'expired', ended_at = coalesce(ended_at, now())
   where status in ('canceled', 'past_due', 'active', 'trialing')
     and current_period_end is not null
     and current_period_end < now() - interval '7 days'
     and (provider <> 'stripe' or status in ('canceled', 'past_due'));
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.expire_lapsed_subscriptions() from public, anon, authenticated;

-- Publish reports whose scheduled time has come.
create or replace function public.publish_scheduled_reports()
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.reports set status = 'published'
   where status = 'scheduled' and publish_at is not null and publish_at <= now() and pdf_path is not null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.publish_scheduled_reports() from public, anon, authenticated;

-- =====================================================================
-- Admin reporting views (only return rows for staff)
-- =====================================================================
create or replace view public.admin_subscriptions with (security_invoker = true) as
select s.id, s.status, s.created_at, s.current_period_end, s.cancel_at_period_end, s.source,
       p.slug as plan, p.kind, pp.billing_interval, pp.currency, pp.amount_minor,
       pr.email, pr.full_name, pr.organisation_name, pr.audience, pr.country_code,
       o.name as organisation
from public.subscriptions s
join public.plans p on p.id = s.plan_id
left join public.plan_prices pp on pp.id = s.price_id
left join public.profiles pr on pr.id = s.user_id
left join public.organisations o on o.id = s.organisation_id;

-- Monthly recurring revenue, normalised: quarterly ÷ 3, yearly ÷ 12.
create or replace view public.admin_mrr with (security_invoker = true) as
select p.slug as plan, p.kind, pp.currency,
       count(*) filter (where s.status in ('active', 'trialing', 'past_due')) as live_subscriptions,
       round(sum(case pp.billing_interval when 'month' then pp.amount_minor when 'quarter' then pp.amount_minor / 3.0
                                         when 'year' then pp.amount_minor / 12.0 else 0 end * s.quantity)
             filter (where s.status in ('active', 'past_due')) / 100.0, 2) as mrr_major
from public.subscriptions s
join public.plans p on p.id = s.plan_id
join public.plan_prices pp on pp.id = s.price_id
group by p.slug, p.kind, pp.currency;

create or replace view public.admin_print_queue with (security_invoker = true) as
select d.id, d.status, d.copies, d.created_at, r.period_label, r.title_en as report,
       pr.full_name, pr.email, d.address_snapshot, d.carrier, d.tracking_number
from public.print_deliveries d
join public.reports r on r.id = d.report_id
left join public.profiles pr on pr.id = d.user_id
where d.status in ('queued', 'on_hold', 'printing')
order by d.created_at;

create or replace view public.admin_funnel_daily with (security_invoker = true) as
select date_trunc('day', created_at)::date as day, event, module_key, count(*) as events,
       count(distinct coalesce(user_id::text, anon_id)) as people
from public.content_events
group by 1, 2, 3;

-- =====================================================================
-- Row level security
-- =====================================================================
alter table public.profiles               enable row level security;
alter table public.organisations          enable row level security;
alter table public.organisation_members   enable row level security;
alter table public.modules                enable row level security;
alter table public.plans                  enable row level security;
alter table public.plan_modules           enable row level security;
alter table public.plan_prices            enable row level security;
alter table public.billing_customers      enable row level security;
alter table public.addresses              enable row level security;
alter table public.subscriptions          enable row level security;
alter table public.payments               enable row level security;
alter table public.reports                enable row level security;
alter table public.print_deliveries       enable row level security;
alter table public.report_downloads       enable row level security;
alter table public.content_events         enable row level security;
alter table public.newsletter_subscribers enable row level security;
alter table public.enquiries              enable row level security;
alter table public.webhook_events         enable row level security;
alter table public.audit_log              enable row level security;

-- Profiles
create policy "profiles: read own or staff" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_staff());
create policy "profiles: update own or admin" on public.profiles for update to authenticated
  using (id = (select auth.uid()) or public.is_admin()) with check (id = (select auth.uid()) or public.is_admin());

-- Organisations
create policy "orgs: members read" on public.organisations for select to authenticated
  using (public.is_staff() or id in (select public.my_org_ids()));
create policy "orgs: admin write" on public.organisations for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "org members: read own org" on public.organisation_members for select to authenticated
  using (user_id = (select auth.uid()) or public.is_staff()
         or organisation_id in (select public.my_org_ids(true)));
create policy "org members: admin write" on public.organisation_members for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Catalogue: public read, admin write
create policy "modules: public read" on public.modules for select to anon, authenticated using (true);
create policy "modules: admin write" on public.modules for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "plans: public read" on public.plans for select to anon, authenticated using ((is_active and is_public) or public.is_admin());
create policy "plans: admin write" on public.plans for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "plan_modules: public read" on public.plan_modules for select to anon, authenticated using (true);
create policy "plan_modules: admin write" on public.plan_modules for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "plan_prices: public read" on public.plan_prices for select to anon, authenticated using (is_active or public.is_admin());
create policy "plan_prices: admin write" on public.plan_prices for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Billing: read own; writes only via service role (Edge Functions)
create policy "billing_customers: read own" on public.billing_customers for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());
create policy "subscriptions: read own or org" on public.subscriptions for select to authenticated
  using (user_id = (select auth.uid()) or public.is_staff()
         or organisation_id in (select public.my_org_ids()));
create policy "subscriptions: admin write" on public.subscriptions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "payments: read own" on public.payments for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());

-- Addresses: full control of own
create policy "addresses: own" on public.addresses for all to authenticated
  using (user_id = (select auth.uid()) or public.is_admin())
  with check (user_id = (select auth.uid()) or public.is_admin());

-- Reports: anyone sees published metadata (titles, covers); the PDF itself is protected in Storage
create policy "reports: read published" on public.reports for select to anon, authenticated
  using (status in ('published', 'scheduled') or public.is_staff());
create policy "reports: staff write" on public.reports for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

create policy "deliveries: read own" on public.print_deliveries for select to authenticated
  using (user_id = (select auth.uid()) or public.is_staff());
create policy "deliveries: staff update" on public.print_deliveries for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

create policy "downloads: insert own" on public.report_downloads for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "downloads: staff read" on public.report_downloads for select to authenticated using (public.is_staff());

-- Analytics & leads: write-only for the public, readable by staff
create policy "events: insert" on public.content_events for insert to anon, authenticated
  with check (user_id is null or user_id = (select auth.uid()));
create policy "events: staff read" on public.content_events for select to authenticated using (public.is_staff());
create policy "newsletter: subscribe" on public.newsletter_subscribers for insert to anon, authenticated
  with check (unsubscribed_at is null and (user_id is null or user_id = (select auth.uid())));
create policy "newsletter: staff read" on public.newsletter_subscribers for select to authenticated using (public.is_staff());
create policy "enquiries: submit" on public.enquiries for insert to anon, authenticated
  with check (user_id is null or user_id = (select auth.uid()));
create policy "enquiries: staff manage" on public.enquiries for all to authenticated using (public.is_staff()) with check (public.is_staff());

create policy "webhooks: admin read" on public.webhook_events for select to authenticated using (public.is_admin());
create policy "audit: admin read" on public.audit_log for select to authenticated using (public.is_admin());

-- Column grants: anon may only send these fields
revoke insert on public.content_events from anon, authenticated;
grant insert (user_id, anon_id, event, module_key, plan_slug, lang, referrer) on public.content_events to anon, authenticated;
revoke insert on public.newsletter_subscribers from anon, authenticated;
grant insert (email, user_id, source, lang) on public.newsletter_subscribers to anon, authenticated;
revoke insert on public.enquiries from anon, authenticated;
grant insert (user_id, name, email, organisation, topic, seats, message) on public.enquiries to anon, authenticated;
revoke update on public.profiles from authenticated;
grant update (full_name, job_title, organisation_name, audience, country_code, phone, preferred_language, marketing_opt_in, role) on public.profiles to authenticated;

grant execute on function public.my_access() to anon, authenticated;
grant execute on function public.has_module(text) to anon, authenticated;
grant execute on function public.has_report_access(public.billing_interval) to authenticated;
grant select on public.pricing_catalogue to anon, authenticated;
