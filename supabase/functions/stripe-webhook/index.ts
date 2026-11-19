// stripe-webhook — Stripe calls this whenever a payment or subscription changes.
// It keeps public.subscriptions, public.payments and shipping addresses in step with Stripe.
// Deploy with JWT verification OFF (Stripe signs requests instead).
// Env: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
// Stripe events to send: checkout.session.completed, customer.subscription.created,
//   customer.subscription.updated, customer.subscription.deleted, invoice.paid,
//   invoice.payment_failed, charge.refunded
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { httpClient: Stripe.createFetchHttpClient() });
const crypto = Stripe.createSubtleCryptoProvider();
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const ts = (s?: number | null) => (s ? new Date(s * 1000).toISOString() : null);
// deno-lint-ignore no-explicit-any
type Any = any;

async function userIdForCustomer(customerId: string, fallback?: string | null): Promise<string | null> {
  if (fallback) return fallback;
  const { data } = await admin.from("billing_customers").select("user_id").eq("provider_customer_id", customerId).maybeSingle();
  if (data?.user_id) return data.user_id;
  const c = (await stripe.customers.retrieve(customerId)) as Any;
  return c?.metadata?.user_id || null;
}

async function upsertSubscription(sub: Any, extra: Record<string, unknown> = {}) {
  const item = sub.items?.data?.[0];
  const stripePriceId = item?.price?.id;
  const { data: price } = await admin.from("plan_prices").select("id, plan_id").eq("provider_price_id", stripePriceId).maybeSingle();
  if (!price) throw new Error(`Unknown Stripe price ${stripePriceId} — add it to plan_prices.provider_price_id`);

  const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
  const userId = await userIdForCustomer(customerId, sub.metadata?.user_id);
  if (!userId) throw new Error(`No user for customer ${customerId}`);

  // Newer Stripe API versions keep the billing period on the subscription item.
  const periodStart = sub.current_period_start ?? item?.current_period_start;
  const periodEnd = sub.current_period_end ?? item?.current_period_end;

  const row = {
    user_id: userId,
    plan_id: price.plan_id,
    price_id: price.id,
    status: sub.status === "incomplete_expired" ? "expired" : sub.status,
    quantity: item?.quantity ?? 1,
    current_period_start: ts(periodStart),
    current_period_end: ts(periodEnd),
    trial_end: ts(sub.trial_end),
    cancel_at_period_end: !!sub.cancel_at_period_end || !!sub.cancel_at,
    canceled_at: ts(sub.canceled_at),
    ended_at: ts(sub.ended_at),
    provider: "stripe",
    provider_customer_id: customerId,
    provider_subscription_id: sub.id,
    metadata: sub.metadata || {},
    ...extra,
  };
  const { data, error } = await admin.from("subscriptions")
    .upsert(row, { onConflict: "provider_subscription_id" }).select("id, user_id").single();
  if (error) throw error;
  return data;
}

async function saveShippingAddress(userId: string, session: Any): Promise<string | null> {
  const ship = session.collected_information?.shipping_details || session.shipping_details;
  const a = ship?.address;
  if (!a?.line1) return null;
  const { data: hasDefault } = await admin.from("addresses").select("id").eq("user_id", userId).eq("is_default", true).maybeSingle();
  const { data, error } = await admin.from("addresses").insert({
    user_id: userId,
    label: "From checkout",
    recipient_name: ship.name || session.customer_details?.name || "Subscriber",
    line1: a.line1, line2: a.line2, city: a.city || "", region: a.state, postcode: a.postal_code,
    country_code: a.country, phone: session.customer_details?.phone,
    is_default: !hasDefault,
  }).select("id").single();
  if (error) throw error;
  return data.id;
}

async function upsertInvoice(inv: Any, status: "succeeded" | "failed") {
  const subId = inv.subscription ?? inv.parent?.subscription_details?.subscription;
  let subscriptionRow: Any = null;
  if (subId) {
    const { data } = await admin.from("subscriptions").select("id, user_id").eq("provider_subscription_id", subId).maybeSingle();
    subscriptionRow = data;
  }
  const userId = subscriptionRow?.user_id || await userIdForCustomer(inv.customer, inv.metadata?.user_id);
  const line = inv.lines?.data?.[0];
  const tax = (inv.total_taxes || []).reduce((n: number, t: Any) => n + (t.amount || 0), 0) || inv.tax || 0;
  const { error } = await admin.from("payments").upsert({
    user_id: userId,
    subscription_id: subscriptionRow?.id ?? null,
    amount_minor: status === "succeeded" ? inv.amount_paid : inv.amount_due,
    tax_minor: tax,
    currency: String(inv.currency || "gbp").toUpperCase(),
    status,
    provider: "stripe",
    provider_invoice_id: inv.id,
    provider_payment_id: typeof inv.payment_intent === "string" ? inv.payment_intent : null,
    invoice_number: inv.number,
    hosted_invoice_url: inv.hosted_invoice_url,
    invoice_pdf_url: inv.invoice_pdf,
    failure_reason: status === "failed" ? (inv.last_finalization_error?.message || "Card payment failed") : null,
    period_start: ts(line?.period?.start),
    period_end: ts(line?.period?.end),
    paid_at: status === "succeeded" ? ts(inv.status_transitions?.paid_at) : null,
  }, { onConflict: "provider_invoice_id" });
  if (error) throw error;
}

Deno.serve(async (req) => {
  const signature = req.headers.get("Stripe-Signature");
  const body = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature!, Deno.env.get("STRIPE_WEBHOOK_SECRET")!, undefined, crypto);
  } catch (e) {
    console.error("Bad signature", e);
    return new Response("Invalid signature", { status: 400 });
  }

  // Idempotency: Stripe retries, so skip events already processed.
  const { data: seen } = await admin.from("webhook_events").select("processed_at").eq("id", event.id).maybeSingle();
  if (seen?.processed_at) return new Response("Already processed", { status: 200 });
  if (!seen) await admin.from("webhook_events").insert({ id: event.id, type: event.type, payload: event as Any });

  try {
    const obj = event.data.object as Any;
    switch (event.type) {
      case "checkout.session.completed": {
        if (obj.mode !== "subscription" || !obj.subscription) break;
        const sub = await stripe.subscriptions.retrieve(obj.subscription as string);
        const saved = await upsertSubscription(sub);
        const addressId = await saveShippingAddress(saved.user_id, obj);
        if (addressId) await admin.from("subscriptions").update({ shipping_address_id: addressId }).eq("id", saved.id);
        await admin.from("content_events").insert({ user_id: saved.user_id, event: "checkout_success", plan_slug: sub.metadata?.plan_slug });
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted":
      case "customer.subscription.paused":
      case "customer.subscription.resumed":
        await upsertSubscription(obj);
        break;
      case "invoice.paid":
        await upsertInvoice(obj, "succeeded");
        break;
      case "invoice.payment_failed":
        await upsertInvoice(obj, "failed");
        break;
      case "charge.refunded": {
        const inv = obj.invoice ?? obj.payment_details?.invoice;
        if (inv) {
          await admin.from("payments")
            .update({ status: obj.amount_refunded >= obj.amount ? "refunded" : "partially_refunded" })
            .eq("provider_invoice_id", inv);
        }
        break;
      }
      default:
        break; // ignored event types are still logged in webhook_events
    }
    await admin.from("webhook_events").update({ processed_at: new Date().toISOString(), error: null }).eq("id", event.id);
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(event.type, e);
    await admin.from("webhook_events").update({ error: String((e as Error)?.message || e) }).eq("id", event.id);
    return new Response("Handler error", { status: 500 }); // Stripe will retry
  }
});
