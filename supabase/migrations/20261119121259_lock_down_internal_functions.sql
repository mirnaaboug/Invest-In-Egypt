-- Migration 3: keep internal functions off the public API.
-- Trigger functions are never called directly.
revoke execute on function public.after_report_published(), public.on_report_published(), public.guard_profile_role(),
  public.handle_new_user(), public.handle_user_email_change(), public.release_on_hold_deliveries(), public.set_updated_at()
  from public, anon, authenticated;
-- Signed-in only helpers.
revoke execute on function public.my_org_ids(boolean) from public, anon;
grant  execute on function public.my_org_ids(boolean) to authenticated;
revoke execute on function public.has_report_access(public.billing_interval) from public, anon;
grant  execute on function public.has_report_access(public.billing_interval) to authenticated;
revoke execute on function public.queue_print_run(uuid) from public, anon;
grant  execute on function public.queue_print_run(uuid) to authenticated;   -- function itself rejects non-staff
-- my_access, has_module, is_admin, is_staff stay callable: they only describe the caller's own access,
-- and the public catalogue policies need is_admin() for anonymous visitors.
