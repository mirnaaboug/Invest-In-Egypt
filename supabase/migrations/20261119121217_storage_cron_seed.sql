-- =====================================================================
-- Migration 2: storage buckets, scheduled jobs, catalogue seed
-- =====================================================================

-- Admin views are staff tools: keep them away from anonymous visitors.
revoke all on public.admin_subscriptions, public.admin_mrr, public.admin_print_queue, public.admin_funnel_daily from anon;

-- ---------- Storage ---------------------------------------------------
-- reports        private  PDFs, stored as <frequency>/<slug>.pdf  e.g. quarter/q4-2026-outlook.pdf
-- report-covers  public   cover images shown on the website
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('reports', 'reports', false, 52428800, array['application/pdf']),
       ('report-covers', 'report-covers', true, 5242880, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

create policy "reports pdf: subscribers download" on storage.objects for select to authenticated
  using (bucket_id = 'reports' and public.has_report_access(
    case (storage.foldername(name))[1]
      when 'month' then 'month'::public.billing_interval
      when 'quarter' then 'quarter'::public.billing_interval
      when 'year' then 'year'::public.billing_interval
      else null end));
create policy "reports pdf: staff upload" on storage.objects for insert to authenticated
  with check (bucket_id in ('reports', 'report-covers') and public.is_staff());
create policy "reports pdf: staff update" on storage.objects for update to authenticated
  using (bucket_id in ('reports', 'report-covers') and public.is_staff());
create policy "reports pdf: staff delete" on storage.objects for delete to authenticated
  using (bucket_id in ('reports', 'report-covers') and public.is_staff());

-- ---------- Scheduled jobs (pg_cron) ---------------------------------
do $cron$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('gateway-expire-lapsed',     '17 2 * * *',  'select public.expire_lapsed_subscriptions()');
    perform cron.schedule('gateway-publish-scheduled', '*/30 * * * *', 'select public.publish_scheduled_reports()');
  end if;
end
$cron$;

-- ---------- Catalogue seed --------------------------------------------
insert into public.modules (key, name_en, name_ar, section_anchor, is_free, sort_order) values
  ('figures',       'Egypt in numbers',                 'مصر بالأرقام',            'figures',       true,  1),
  ('why',           'Why Egypt',                        'لماذا مصر',               'why',           true,  2),
  ('map',           'Africa map and country indicators','خريطة أفريقيا ومؤشرات الدول','map',          false, 3),
  ('agreements',    'Trade and bilateral agreements',   'الاتفاقيات التجارية والثنائية','agreements', false, 4),
  ('trade',         'UK–Egypt trade',                   'التجارة البريطانية المصرية', 'trade',        false, 5),
  ('sectors',       'Sector profiles',                  'ملفات القطاعات',           'sectors',       false, 6),
  ('hubs',          'Industrial hubs and logistics',    'المراكز الصناعية واللوجستيات','hubs',         false, 7),
  ('toolkit',       'Investor toolkit',                 'أدوات المستثمر',           'toolkit',       false, 8),
  ('opportunities', 'Market gaps and opportunities',    'الفجوات والفرص',           'opportunities', false, 9),
  ('news',          'Investment news',                  'أخبار الاستثمار',          'news',          false, 10),
  ('policy',        'Foreign policy and relations',     'السياسة الخارجية',         'policy',        false, 11),
  ('sources',       'Data and sources',                 'البيانات والمصادر',        'sources',       true,  12);

insert into public.plans (slug, kind, name_en, name_ar, tagline_en, tagline_ar, features, seats, includes_pdf, report_frequency, print_copies, trial_days, sort_order) values
  ('explorer', 'access', 'Explorer', 'مستكشف',
   'Free account: the headline case for Egypt.', 'حساب مجاني: الصورة العامة لمصر.',
   '["Egypt in numbers and the investment case","A preview of every module","Data and sources table","Monthly data-update email"]', 1, false, null, 0, 0, 10),
  ('trade-access', 'access', 'Trade Access', 'الوصول التجاري',
   'For exporters: agreements, trade data, ports and set-up steps.', 'للمصدّرين: الاتفاقيات وبيانات التجارة والموانئ وخطوات التأسيس.',
   '["Free trade and bilateral agreements","UK–Egypt trade data and charts","Industrial hubs, ports and logistics","Investor toolkit and official links"]', 1, false, null, 0, 0, 20),
  ('market-intelligence', 'access', 'Market Intelligence', 'معلومات السوق',
   'For investors: the Africa map, sectors, gaps and news.', 'للمستثمرين: خريطة أفريقيا والقطاعات والفرص والأخبار.',
   '["Interactive Africa map and country indicators","Sector profiles","Market gaps and opportunities","Investment and infrastructure news"]', 1, false, null, 0, 0, 30),
  ('full-gateway', 'access', 'Full Gateway', 'البوابة الكاملة',
   'Everything on the platform, for a small team.', 'كل محتوى المنصة لفريق صغير.',
   '["All 10 modules, including foreign policy","Every report as a downloadable PDF","Country one-pagers","3 team seats","7-day free trial"]', 3, true, null, 0, 7, 40),
  ('enterprise', 'enterprise', 'Institutional', 'المؤسسات',
   'For government teams, chambers and funds.', 'للفرق الحكومية والغرف التجارية والصناديق.',
   '["Full Gateway for up to 25 seats","Printed reports for every office","Invoiced billing","Briefings with the data team"]', 25, true, null, 0, 0, 50),
  ('monthly-monitor', 'report', 'Monthly Trade Monitor', 'المرصد التجاري الشهري',
   'A 12-page printed brief, posted every month.', 'نشرة مطبوعة من 12 صفحة تصلك كل شهر.',
   '["Printed and posted every month","Trade, FX and investment figures with sources","PDF copy of each issue","Cancel any time"]', 1, false, 'month', 1, 0, 60),
  ('quarterly-outlook', 'report', 'Quarterly Outlook', 'التقرير الربع سنوي',
   'A 40-page printed report with sector deep-dives, every quarter.', 'تقرير مطبوع من 40 صفحة مع تحليل القطاعات كل ربع سنة.',
   '["Printed and posted every quarter","Two sector deep-dives per issue","Africa regional scorecard","PDF copy of each issue"]', 1, false, 'quarter', 1, 0, 70),
  ('annual-yearbook', 'report', 'Annual Yearbook', 'الكتاب السنوي',
   'The full Egypt Gateway Yearbook, printed and bound.', 'كتاب البوابة السنوي كاملًا، مطبوعًا ومجلدًا.',
   '["Printed, bound yearbook (about 120 pages)","Every module in one reference volume","Two copies posted","PDF copy included"]', 1, false, 'year', 2, 0, 80);

insert into public.plan_modules (plan_id, module_key)
select p.id, m.key from public.plans p
join public.modules m on not m.is_free and (
     (p.slug = 'trade-access'        and m.key in ('agreements', 'trade', 'hubs', 'toolkit'))
  or (p.slug = 'market-intelligence' and m.key in ('map', 'sectors', 'opportunities', 'news'))
  or (p.slug in ('full-gateway', 'enterprise'))
  or (p.slug = 'monthly-monitor'     and m.key in ('news'))
  or (p.slug = 'quarterly-outlook'   and m.key in ('news', 'sectors'))
  or (p.slug = 'annual-yearbook'     and m.key in ('news', 'sectors', 'agreements')));

-- Placeholder prices in GBP pence, VAT exclusive. Change before going live.
insert into public.plan_prices (plan_id, billing_interval, currency, amount_minor)
select p.id, v.iv::public.billing_interval, 'GBP', v.amount
from public.plans p
join (values
  ('trade-access',        'month',   3900),
  ('trade-access',        'year',    39000),
  ('market-intelligence', 'month',   5900),
  ('market-intelligence', 'year',    59000),
  ('full-gateway',        'month',   9900),
  ('full-gateway',        'year',    99000),
  ('monthly-monitor',     'month',   4900),
  ('quarterly-outlook',   'quarter', 14900),
  ('annual-yearbook',     'year',    34900)
) as v(slug, iv, amount) on v.slug = p.slug;

-- First editions, scheduled. They publish automatically once a PDF is uploaded and the date passes.
insert into public.reports (slug, frequency, title_en, title_ar, summary_en, period_label, period_start, period_end, page_count, module_keys, status, publish_at) values
  ('monitor-2026-12', 'month', 'Egypt Trade Monitor', 'المرصد التجاري لمصر',
   'Monthly trade, currency and investment figures for UK–Egypt business, with sources.', 'December 2026', '2026-12-01', '2026-12-31', 12, '{trade,news}', 'scheduled', '2026-12-05 09:00+00'),
  ('outlook-2026-q4', 'quarter', 'Egypt Gateway Quarterly Outlook', 'التوقعات الربع سنوية',
   'Quarterly review with sector deep-dives on renewable energy and logistics.', 'Q4 2026', '2026-10-01', '2026-12-31', 40, '{sectors,opportunities,map}', 'scheduled', '2027-01-15 09:00+00'),
  ('yearbook-2026', 'year', 'Egypt Gateway Yearbook', 'الكتاب السنوي للبوابة',
   'The full reference volume: agreements, sectors, hubs, the Africa map and country indicators.', '2026 Yearbook', '2026-01-01', '2026-12-31', 120, '{agreements,sectors,hubs,map,toolkit}', 'scheduled', '2027-01-31 09:00+00');
