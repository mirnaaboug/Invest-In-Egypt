// billing-portal — opens Stripe's hosted page where a subscriber can update their card,
// download invoices, change plan or cancel.
//   supabase.functions.invoke('billing-portal', { body: { return_url } })
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const stripe = stripeClient();
  if (!stripe) return json({ error: "Online payments aren't switched on yet. Please try again later." }, 503);
  try {
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return json({ error: "Please sign in first." }, 401);

    const { data: bc } = await admin.from("billing_customers").select("provider_customer_id").eq("user_id", user.id).maybeSingle();
    if (!bc) return json({ error: "No billing account yet. Choose a package first." }, 404);

    const { return_url } = await req.json().catch(() => ({}));
    const site = (Deno.env.get("SITE_URL") || "").replace(/\/$/, "");
    let back = site;
    if (typeof return_url === "string" && return_url.startsWith("https://")) {
      const u = new URL(return_url);
      if (!site || u.origin === new URL(site).origin) back = u.origin + u.pathname;
    }
    const session = await stripe.billingPortal.sessions.create({
      customer: bc.provider_customer_id,
      return_url: `${back}#account`,
    });
    return json({ url: session.url });
  } catch (e) {
    console.error(e);
    return json({ error: "Could not open billing. Please try again." }, 500);
  }
});
