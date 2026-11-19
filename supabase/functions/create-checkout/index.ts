// create-checkout — starts a Stripe Checkout session for one of our plan_prices.
// Called by the website with the signed-in user's token:
//   supabase.functions.invoke('create-checkout', { body: { price_id, return_url } })
// Env (Edge Function secrets): STRIPE_SECRET_KEY, SITE_URL (e.g. https://egyptgateway.org),
//   optional STRIPE_AUTOMATIC_TAX=true once Stripe Tax is set up.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Created on first use so a missing key returns a clear message instead of crashing the function.
let _stripe: Stripe | null = null;
function stripeClient(): Stripe | null {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) return null;
  return (_stripe ??= new Stripe(key, { httpClient: Stripe.createFetchHttpClient() }));
}
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

// Countries we post printed reports to. Extend as needed.
const SHIP_TO = ["GB", "EG", "IE", "AE", "SA", "US", "FR", "DE", "NL", "BE", "KE", "NG", "ZA", "MA", "TN", "JO", "QA", "KW", "BH", "OM"];

function safeReturnUrl(candidate: unknown): string {
  const site = (Deno.env.get("SITE_URL") || "").replace(/\/$/, "");
  if (typeof candidate === "string" && candidate.startsWith("https://")) {
    try {
      const u = new URL(candidate);
      if (!site || u.origin === new URL(site).origin) return u.origin + u.pathname;
    } catch { /* fall through */ }
  }
  return site || "https://example.com";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const stripe = stripeClient();
  if (!stripe) return json({ error: "Online payments aren't switched on yet. Please try again later." }, 503);
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: { user }, error: authErr } = await admin.auth.getUser(token);
    if (authErr || !user) return json({ error: "Please sign in first." }, 401);

    const { price_id, return_url } = await req.json();
    if (!price_id) return json({ error: "price_id is required" }, 400);

    const { data: price, error: priceErr } = await admin
      .from("plan_prices")
      .select("id, provider_price_id, billing_interval, is_active, plan:plans(id, slug, kind, trial_days, is_active)")
      .eq("id", price_id)
      .single();
    // deno-lint-ignore no-explicit-any
    const plan = (price as any)?.plan;
    if (priceErr || !price || !price.is_active || !plan?.is_active) return json({ error: "That package is not available." }, 404);
    if (!price.provider_price_id) return json({ error: "That package is not set up for online payment yet." }, 409);
    if (plan.kind === "enterprise") return json({ error: "Institutional plans are arranged by invoice. Please send an enquiry." }, 400);

    // Block a duplicate of a plan the user already holds.
    const { data: existing } = await admin
      .from("subscriptions")
      .select("id")
      .eq("user_id", user.id)
      .eq("plan_id", plan.id)
      .in("status", ["active", "trialing", "past_due"])
      .limit(1);
    if (existing && existing.length) return json({ error: "You already have this package. Manage it from your account." }, 409);

    // Reuse or create the Stripe customer.
    let customerId: string | undefined;
    const { data: bc } = await admin.from("billing_customers").select("provider_customer_id").eq("user_id", user.id).maybeSingle();
    if (bc?.provider_customer_id) {
      customerId = bc.provider_customer_id;
    } else {
      const { data: profile } = await admin.from("profiles").select("full_name, organisation_name").eq("id", user.id).maybeSingle();
      const customer = await stripe.customers.create({
        email: user.email,
        name: profile?.full_name || undefined,
        metadata: { user_id: user.id, organisation: profile?.organisation_name || "" },
      });
      customerId = customer.id;
      await admin.from("billing_customers").insert({ user_id: user.id, provider_customer_id: customerId });
    }

    // Free trial only the first time someone takes this plan.
    let trialDays: number | undefined;
    if (plan.trial_days > 0) {
      const { count } = await admin.from("subscriptions").select("id", { count: "exact", head: true })
        .eq("user_id", user.id).eq("plan_id", plan.id);
      if (!count) trialDays = plan.trial_days;
    }

    const base = safeReturnUrl(return_url);
    const meta = { user_id: user.id, plan_id: plan.id, plan_slug: plan.slug, price_id: price.id };
    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerId,
      client_reference_id: user.id,
      line_items: [{ price: price.provider_price_id, quantity: 1 }],
      allow_promotion_codes: true,
      billing_address_collection: "required",
      tax_id_collection: { enabled: true },
      customer_update: { address: "auto", name: "auto", ...(plan.kind === "report" ? { shipping: "auto" } : {}) },
      ...(plan.kind === "report" ? { shipping_address_collection: { allowed_countries: SHIP_TO as Stripe.Checkout.SessionCreateParams.ShippingAddressCollection.AllowedCountry[] } } : {}),
      ...(Deno.env.get("STRIPE_AUTOMATIC_TAX") === "true" ? { automatic_tax: { enabled: true } } : {}),
      subscription_data: { metadata: meta, ...(trialDays ? { trial_period_days: trialDays } : {}) },
      metadata: meta,
      success_url: `${base}?checkout=success&session_id={CHECKOUT_SESSION_ID}#account`,
      cancel_url: `${base}?checkout=cancelled#pricing`,
    });

    await admin.from("content_events").insert({ user_id: user.id, event: "checkout_start", plan_slug: plan.slug });
    return json({ url: session.url });
  } catch (e) {
    console.error(e);
    return json({ error: "Could not start checkout. Please try again." }, 500);
  }
});
