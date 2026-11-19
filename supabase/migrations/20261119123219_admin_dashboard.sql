-- Migration 4: one secure call that feeds the admin page (/admin/).
-- Staff (role editor or admin) only. Everything else the admin page does goes
-- through normal table updates, which row-level security already limits to staff.
create or replace function public.admin_dashboard()
returns json language plpgsql stable security definer set search_path = '' as $fn$
begin
  if not public.is_staff() then
    raise exception 'Admins and editors only' using errcode = '42501';
  end if;
  return json_build_object(
 'kpi', json_build_object(
   'users',        (select count(*) from public.profiles),
   'users7',       (select count(*) from public.profiles where created_at > now() - interval '7 days'),
   'active',       (select count(*) from public.subscriptions where status in ('active','trialing')),
   'trialing',     (select count(*) from public.subscriptions where status = 'trialing'),
   'past_due',     (select count(*) from public.subscriptions where status = 'past_due'),
   'cancelling',   (select count(*) from public.subscriptions where cancel_at_period_end and status in ('active','trialing')),
   'mrr',          (select coalesce(sum(mrr_major),0) from public.admin_mrr where currency = 'GBP'),
   'paywall7',     (select count(*) from public.content_events where event = 'paywall_view' and created_at > now() - interval '7 days'),
   'clicks7',      (select count(*) from public.content_events where event = 'plan_click' and created_at > now() - interval '7 days'),
   'checkout7',    (select count(*) from public.content_events where event = 'checkout_start' and created_at > now() - interval '7 days'),
   'paid7',        (select count(*) from public.content_events where event = 'checkout_success' and created_at > now() - interval '7 days'),
   'newsletter',   (select count(*) from public.newsletter_subscribers where unsubscribed_at is null),
   'to_print',     (select count(*) from public.print_deliveries where status in ('queued','printing')),
   'on_hold',      (select count(*) from public.print_deliveries where status = 'on_hold'),
   'enq_new',      (select count(*) from public.enquiries where status = 'new'),
   'wh_errors',    (select count(*) from public.webhook_events where error is not null and processed_at is null),
   'revenue30',    (select coalesce(sum(amount_minor),0) from public.payments where status = 'succeeded' and paid_at > now() - interval '30 days')
 ),
 'plans', (select coalesce(json_agg(x order by x.sort_order), '[]') from (
     select p.id, p.slug, p.kind, p.name_en, p.sort_order, p.report_frequency,
       (select count(*) from public.subscriptions s where s.plan_id = p.id and s.status in ('active','trialing','past_due')) as live,
       (select coalesce(m.mrr_major,0) from public.admin_mrr m where m.plan = p.slug and m.currency = 'GBP') as mrr,
       (select json_agg(json_build_object('interval', pp.billing_interval, 'amount_minor', pp.amount_minor, 'linked', pp.provider_price_id is not null) order by pp.billing_interval)
          from public.plan_prices pp where pp.plan_id = p.id and pp.is_active) as prices
     from public.plans p where p.is_active) x),
 'subs', (select coalesce(json_agg(x), '[]') from (
     select s.id, s.status, s.created_at, s.current_period_end, s.cancel_at_period_end, s.source, s.provider_subscription_id,
            p.slug as plan, p.name_en as plan_name, p.kind, pp.billing_interval, pp.amount_minor, pp.currency,
            pr.email, pr.full_name, pr.organisation_name, pr.audience, pr.country_code
     from public.subscriptions s join public.plans p on p.id = s.plan_id
     left join public.plan_prices pp on pp.id = s.price_id left join public.profiles pr on pr.id = s.user_id
     order by s.created_at desc limit 300) x),
 'deliveries', (select coalesce(json_agg(x), '[]') from (
     select d.id, d.status, d.copies, d.carrier, d.tracking_number, d.tracking_url, d.created_at, d.dispatched_at, d.delivered_at, d.address_snapshot,
            r.title_en as report, r.period_label, pr.full_name, pr.email
     from public.print_deliveries d join public.reports r on r.id = d.report_id left join public.profiles pr on pr.id = d.user_id
     order by case d.status when 'on_hold' then 0 when 'queued' then 1 when 'printing' then 2 when 'dispatched' then 3 else 4 end, d.created_at desc
     limit 400) x),
 'reports', (select coalesce(json_agg(x), '[]') from (
     select r.id, r.slug, r.frequency, r.title_en, r.period_label, r.status, r.publish_at, r.published_at, r.pdf_path, r.page_count, r.print_run_queued_at,
            (select count(*) from public.print_deliveries d where d.report_id = r.id) as deliveries,
            (select count(*) from public.report_downloads dl where dl.report_id = r.id) as downloads,
            (select count(*) from public.subscriptions s join public.plans p on p.id = s.plan_id
               where p.kind = 'report' and p.report_frequency = r.frequency and s.status in ('active','trialing')) as eligible
     from public.reports r order by coalesce(r.published_at, r.publish_at, r.created_at) desc limit 100) x),
 'enquiries', (select coalesce(json_agg(x), '[]') from (
     select id, name, email, organisation, topic, seats, message, status, created_at from public.enquiries order by created_at desc limit 200) x),
 'users', (select coalesce(json_agg(x), '[]') from (
     select pr.id, pr.email, pr.full_name, pr.organisation_name, pr.audience, pr.country_code, pr.role, pr.marketing_opt_in, pr.created_at,
            (select string_agg(p.name_en, ', ') from public.subscriptions s join public.plans p on p.id = s.plan_id
               where s.user_id = pr.id and s.status in ('active','trialing','past_due')) as plans
     from public.profiles pr order by pr.created_at desc limit 500) x),
 'funnel', (select coalesce(json_agg(x order by x.paywall desc), '[]') from (
     select module_key, count(*) filter (where event = 'paywall_view') as paywall, count(*) filter (where event = 'plan_click') as clicks
     from public.content_events where created_at > now() - interval '30 days' and module_key is not null group by module_key) x),
 'daily', (select coalesce(json_agg(x order by x.day), '[]') from (
     select g.day::date as day,
       (select count(*) from public.profiles where created_at::date = g.day::date) as signups,
       (select count(*) from public.content_events where event = 'checkout_success' and created_at::date = g.day::date) as purchases,
       (select count(*) from public.content_events where event = 'paywall_view' and created_at::date = g.day::date) as paywall
     from generate_series(current_date - 29, current_date, interval '1 day') g(day)) x),
 'payments', (select coalesce(json_agg(x), '[]') from (
     select pa.id, pa.amount_minor, pa.currency, pa.status, pa.invoice_number, pa.hosted_invoice_url, pa.failure_reason, pa.paid_at, pa.created_at, pr.email
     from public.payments pa left join public.profiles pr on pr.id = pa.user_id order by pa.created_at desc limit 150) x),
 'webhooks', (select coalesce(json_agg(x), '[]') from (
     select id, type, error, received_at from public.webhook_events where error is not null order by received_at desc limit 25) x),
 'newsletter', (select coalesce(json_agg(email order by consent_at desc), '[]') from public.newsletter_subscribers where unsubscribed_at is null),
 'generated_at', now()
);
end
$fn$;
revoke execute on function public.admin_dashboard() from public, anon;
grant execute on function public.admin_dashboard() to authenticated;
