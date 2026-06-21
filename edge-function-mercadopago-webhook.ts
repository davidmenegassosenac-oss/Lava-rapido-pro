// ============================================================
// EDGE FUNCTION: mercadopago-webhook
// Lava Rápido SaaS
//
// Endpoint público que o Mercado Pago chama quando o status de
// um pagamento muda (aprovado, recusado, cancelado, etc).
//
// Esta função é GENÉRICA quanto ao tipo de checkout: funciona
// igual se o pagamento vier de cartão recorrente ou de Pix
// gerado manualmente todo mês. O que muda entre esses métodos
// é como a cobrança é CRIADA (em outra função, ainda não
// implementada — depende da decisão de checkout), não como
// o webhook de confirmação é recebido e processado.
//
// SEGURANÇA: o Mercado Pago permite validar a origem da notificação
// via assinatura HMAC no header "x-signature", usando uma chave
// secreta própria (diferente do Access Token). Sem essa validação,
// QUALQUER pessoa poderia forjar uma chamada a este endpoint
// fingindo ser um pagamento aprovado, liberando assinaturas de
// graça. A validação está implementada abaixo e é OBRIGATÓRIA —
// não desative mesmo "só para testar mais rápido".
//
// Deploy:
//   No painel: Edge Functions → Deploy a new function → Via Editor
//   Dê o nome desejado e ANOTE A URL REAL gerada (pode não ser
//   igual ao nome digitado — já vimos esse comportamento antes).
//
// Configurar no Mercado Pago Developers, em Webhooks:
//   URL: <a URL real gerada pelo Supabase>
//   Eventos: pagamentos (payment)
//
// Variáveis de ambiente necessárias (Project Settings → Edge
// Functions → Secrets):
//   SUPABASE_URL                 (já provida automaticamente)
//   SUPABASE_SERVICE_ROLE_KEY    (já provida automaticamente)
//   MERCADOPAGO_ACCESS_TOKEN     (você precisa adicionar)
//   MERCADOPAGO_WEBHOOK_SECRET   (você precisa adicionar — gerado
//                                 no painel do Mercado Pago ao
//                                 configurar o webhook)
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-signature, x-request-id',
};

// ── Validação de assinatura HMAC do Mercado Pago ───────────────────────
// Formato do header x-signature: "ts=1234567890,v1=abc123..."
// O Mercado Pago monta uma string com: "id:{data.id};request-id:{x-request-id};ts:{ts};"
// e gera um HMAC-SHA256 com o webhook secret. Comparamos aqui.
async function validarAssinaturaMercadoPago(req, body, webhookSecret) {
  const signatureHeader = req.headers.get('x-signature');
  const requestId = req.headers.get('x-request-id');
  if (!signatureHeader || !webhookSecret) return false;

  const parts = Object.fromEntries(
    signatureHeader.split(',').map((p) => p.trim().split('='))
  );
  const ts = parts['ts'];
  const v1 = parts['v1'];
  if (!ts || !v1) return false;

  const dataId = body?.data?.id ?? '';
  const manifest = `id:${dataId};request-id:${requestId ?? ''};ts:${ts};`;

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(webhookSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signatureBuffer = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(manifest));
  const computedHex = Array.from(new Uint8Array(signatureBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  return computedHex === v1;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const bodyText = await req.text();
    const body = JSON.parse(bodyText || '{}');

    const webhookSecret = Deno.env.get('MERCADOPAGO_WEBHOOK_SECRET');
    const valido = await validarAssinaturaMercadoPago(req, body, webhookSecret);

    if (!valido) {
      // Não revelamos detalhes do motivo da falha — apenas recusamos.
      return new Response(
        JSON.stringify({ success: false, message: 'Assinatura inválida.' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // O Mercado Pago envia notificações de vários tipos (payment,
    // subscription_preapproval, etc). Por ora processamos apenas
    // eventos de pagamento — é o que importa independente do
    // checkout final ser cartão recorrente ou Pix manual.
    if (body.type !== 'payment') {
      return new Response(JSON.stringify({ success: true, ignored: true }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const paymentId = body.data?.id;
    if (!paymentId) {
      return new Response(JSON.stringify({ success: false, message: 'ID de pagamento ausente.' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Buscar detalhes reais do pagamento na API do Mercado Pago —
    // nunca confiamos cegamente no conteúdo do webhook em si, que
    // pode trazer só o ID; o status oficial vem desta consulta.
    const accessToken = Deno.env.get('MERCADOPAGO_ACCESS_TOKEN');
    const mpRes = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    const mpData = await mpRes.json();

    // Normaliza o status do Mercado Pago para o vocabulário interno
    // do nosso banco, que é o mesmo independente do gateway usado.
    const statusMap = {
      approved: 'aprovado',
      rejected: 'recusado',
      cancelled: 'cancelado',
      refunded: 'cancelado',
      charged_back: 'cancelado',
      pending: 'pendente',
      in_process: 'pendente',
    };
    const statusNormalizado = statusMap[mpData.status] ?? 'pendente';

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL'),
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const { data: resultado, error } = await supabaseAdmin.rpc('fn_processar_webhook', {
      p_gateway: 'mercadopago',
      p_gateway_payment_id: String(paymentId),
      p_status_normalizado: statusNormalizado,
      p_payload: mpData,
    });

    if (error) {
      return new Response(JSON.stringify({ success: false, message: error.message }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify(resultado), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (e) {
    return new Response(
      JSON.stringify({ success: false, message: e.message || 'Erro interno.' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
