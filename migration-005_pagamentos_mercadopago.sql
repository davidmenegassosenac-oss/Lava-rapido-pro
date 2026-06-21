-- ============================================================
-- MIGRAÇÃO 005 — PAGAMENTOS REAIS (independente de gateway)
-- Lava Rápido SaaS
--
-- Generaliza a tabela `cobrancas` (criada pensando só no Asaas)
-- para funcionar com qualquer gateway — Mercado Pago, Asaas,
-- Stripe — e implementa de fato o processamento de webhook,
-- que antes era apenas um stub que registrava e ignorava.
--
-- Esta parte é igual independente de você decidir, no checkout,
-- usar cartão recorrente ou Pix manual mensal — o que muda é só
-- como a cobrança é CRIADA (próxima etapa), não como ela é
-- REGISTRADA e PROCESSADA (esta etapa).
--
-- Execute no SQL Editor do Supabase.
-- ============================================================

-- ── 1. Generalizar coluna específica do Asaas ─────────────────────────
-- asaas_id existia pensando só nesse gateway. Renomeamos para
-- gateway_payment_id (mais genérico) e adicionamos a coluna
-- `gateway` para identificar de qual provedor veio a cobrança.
ALTER TABLE public.cobrancas
  RENAME COLUMN asaas_id TO gateway_payment_id;

ALTER TABLE public.cobrancas
  ADD COLUMN IF NOT EXISTS gateway TEXT NOT NULL DEFAULT 'mercadopago'
    CHECK (gateway IN ('mercadopago', 'asaas', 'stripe', 'manual'));

-- tipo_cobranca já aceitava 'pix'/'cartao'/'boleto'/'manual' — mantemos,
-- pois é igual independente do gateway escolhido.

CREATE INDEX IF NOT EXISTS idx_cobrancas_gateway_payment_id
  ON public.cobrancas(gateway_payment_id);

-- ── 2. Coluna para guardar a referência externa da assinatura ─────────
-- No Mercado Pago, uma assinatura recorrente de cartão (preapproval)
-- tem um ID próprio, separado do ID de cada pagamento individual.
-- Isso é útil mesmo se o checkout final for por Pix manual, porque
-- também serve para guardar uma referência de "plano" no gateway.
ALTER TABLE public.assinaturas
  ADD COLUMN IF NOT EXISTS gateway_subscription_id TEXT,
  ADD COLUMN IF NOT EXISTS gateway TEXT;

-- ── 3. Implementação REAL do processamento de webhook ─────────────────
-- Substitui o stub anterior, que só registrava e marcava como
-- "ignorado". Agora processa de fato os eventos mais comuns de
-- gateways de pagamento brasileiros: pagamento aprovado, recusado,
-- cancelado, e assinatura cancelada pelo cliente.
--
-- O nome dos eventos varia por gateway (ex: Mercado Pago usa
-- "payment.created"/"payment.updated" no header, com o status real
-- dentro do payload). Por isso esta função recebe o status JÁ
-- NORMALIZADO pela Edge Function chamadora, não o formato bruto do
-- gateway — assim a função SQL nunca precisa saber qual gateway foi.
CREATE OR REPLACE FUNCTION public.fn_processar_webhook(
  p_gateway              TEXT,
  p_gateway_payment_id   TEXT,
  p_status_normalizado   TEXT,  -- 'aprovado' | 'recusado' | 'cancelado' | 'pendente'
  p_payload              JSONB
)
RETURNS JSONB AS $$
DECLARE
  v_log_id      UUID;
  v_cobranca    public.cobrancas%ROWTYPE;
  v_novo_status TEXT;
BEGIN
  -- Sempre registrar o evento bruto recebido, para auditoria/debug,
  -- independente do que acontecer no processamento abaixo.
  INSERT INTO public.webhooks_log (gateway, evento, payload, status)
  VALUES (p_gateway, p_status_normalizado, p_payload, 'recebido')
  RETURNING id INTO v_log_id;

  -- Localizar a cobrança correspondente pelo ID externo do gateway
  SELECT * INTO v_cobranca
  FROM public.cobrancas
  WHERE gateway_payment_id = p_gateway_payment_id
  LIMIT 1;

  IF NOT FOUND THEN
    UPDATE public.webhooks_log
    SET status = 'erro', erro_msg = 'Cobrança não encontrada para gateway_payment_id: ' || p_gateway_payment_id,
        processed_at = NOW()
    WHERE id = v_log_id;

    RETURN jsonb_build_object(
      'success', FALSE,
      'log_id', v_log_id,
      'mensagem', 'Cobrança correspondente não encontrada.'
    );
  END IF;

  -- Mapear status normalizado -> status da cobrança e da assinatura
  v_novo_status := CASE p_status_normalizado
    WHEN 'aprovado'  THEN 'pago'
    WHEN 'recusado'  THEN 'cancelado'
    WHEN 'cancelado' THEN 'cancelado'
    ELSE 'pendente'
  END;

  UPDATE public.cobrancas
  SET status = v_novo_status,
      data_pagamento = CASE WHEN v_novo_status = 'pago' THEN CURRENT_DATE ELSE data_pagamento END,
      updated_at = NOW()
  WHERE id = v_cobranca.id;

  -- Se o pagamento foi aprovado, reativa/estende a assinatura por 1 mês
  -- a partir de hoje (não a partir do antigo vencimento, para o caso de
  -- já estar vencida — evita "acumular" tempo perdido).
  IF p_status_normalizado = 'aprovado' THEN
    UPDATE public.assinaturas
    SET status = 'ativo',
        data_pagamento = CURRENT_DATE,
        data_vencimento = CURRENT_DATE + INTERVAL '1 month',
        updated_at = NOW()
    WHERE id = v_cobranca.assinatura_id;

  ELSIF p_status_normalizado IN ('recusado', 'cancelado') THEN
    -- Não derruba a assinatura na hora — apenas registra. A função
    -- fn_assinatura_valida já cuida de marcar como vencida quando a
    -- data_vencimento passar, então um pagamento recusado não corta
    -- o acesso instantaneamente (dá chance de tentar de novo).
    NULL;
  END IF;

  UPDATE public.webhooks_log
  SET status = 'processado', processed_at = NOW()
  WHERE id = v_log_id;

  RETURN jsonb_build_object(
    'success', TRUE,
    'log_id', v_log_id,
    'cobranca_id', v_cobranca.id,
    'novo_status', v_novo_status
  );

EXCEPTION WHEN OTHERS THEN
  UPDATE public.webhooks_log
  SET status = 'erro', erro_msg = SQLERRM, processed_at = NOW()
  WHERE id = v_log_id;
  RETURN jsonb_build_object('success', FALSE, 'log_id', v_log_id, 'mensagem', SQLERRM);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 4. RPC para criar o registro de cobrança no nosso banco ───────────
-- Chamada pela Edge Function ANTES de chamar a API do gateway —
-- assim já temos um ID interno e referência fixa de valor/vencimento,
-- independente de qual checkout (cartão/Pix/boleto) for usado depois.
CREATE OR REPLACE FUNCTION public.fn_criar_cobranca(
  p_empresa_id      UUID,
  p_valor           NUMERIC,
  p_tipo_cobranca   TEXT DEFAULT 'manual',
  p_gateway         TEXT DEFAULT 'mercadopago',
  p_descricao       TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_assinatura_id UUID;
  v_cobranca_id   UUID;
BEGIN
  SELECT id INTO v_assinatura_id
  FROM public.assinaturas WHERE empresa_id = p_empresa_id LIMIT 1;

  IF v_assinatura_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'mensagem', 'Empresa sem assinatura cadastrada.');
  END IF;

  INSERT INTO public.cobrancas (
    empresa_id, assinatura_id, valor, tipo_cobranca, gateway,
    data_vencimento, descricao, status
  ) VALUES (
    p_empresa_id, v_assinatura_id, p_valor, p_tipo_cobranca, p_gateway,
    CURRENT_DATE + INTERVAL '3 days', -- prazo padrão de 3 dias para pagar
    COALESCE(p_descricao, 'Assinatura Lava Rápido Pro'), 'pendente'
  )
  RETURNING id INTO v_cobranca_id;

  RETURN jsonb_build_object('success', TRUE, 'cobranca_id', v_cobranca_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 5. RPC para o owner consultar suas próprias cobranças no app ──────
CREATE OR REPLACE FUNCTION public.fn_listar_cobrancas(p_empresa_id UUID)
RETURNS SETOF public.cobrancas AS $$
  SELECT * FROM public.cobrancas
  WHERE empresa_id = p_empresa_id
  ORDER BY created_at DESC
  LIMIT 24;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Confirmar criação
SELECT routine_name FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name IN
  ('fn_processar_webhook', 'fn_criar_cobranca', 'fn_listar_cobrancas');

-- ============================================================
-- FIM DA MIGRAÇÃO 005
-- Próximo passo: deploy da Edge Function mercadopago-webhook
-- ============================================================
