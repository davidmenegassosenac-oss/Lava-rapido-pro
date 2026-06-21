-- ============================================================
-- MIGRAÇÃO 004 — PREPARAÇÃO PARA WEBHOOKS (Asaas)
-- Lava Rápido SaaS
-- Execute APÓS 003_assinaturas.sql
-- NOTA: Nenhuma cobrança real é implementada aqui.
--       Apenas a estrutura para integração futura.
-- ============================================================

-- ============================================================
-- TABELA: webhooks_log
-- Registra todos os eventos recebidos de gateways de pagamento.
-- Quando integrar com Asaas, os webhooks chegam aqui.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.webhooks_log (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  empresa_id   UUID REFERENCES public.empresas(id) ON DELETE SET NULL,
  gateway      TEXT NOT NULL DEFAULT 'asaas',
  -- futuro: 'asaas', 'stripe', 'mercadopago'
  evento       TEXT NOT NULL,
  -- ex: 'PAYMENT_RECEIVED', 'PAYMENT_OVERDUE', 'SUBSCRIPTION_CANCELLED'
  payload      JSONB NOT NULL DEFAULT '{}',
  status       TEXT NOT NULL DEFAULT 'recebido'
               CHECK (status IN ('recebido', 'processado', 'erro', 'ignorado')),
  erro_msg     TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_webhooks_empresa  ON public.webhooks_log(empresa_id);
CREATE INDEX IF NOT EXISTS idx_webhooks_status   ON public.webhooks_log(status);
CREATE INDEX IF NOT EXISTS idx_webhooks_evento   ON public.webhooks_log(evento);

-- ============================================================
-- TABELA: cobrancas
-- Estrutura preparada para cobranças via Asaas.
-- Quando integrar: preencher asaas_id com o ID retornado pela API.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.cobrancas (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  empresa_id        UUID NOT NULL REFERENCES public.empresas(id) ON DELETE CASCADE,
  assinatura_id     UUID NOT NULL REFERENCES public.assinaturas(id) ON DELETE CASCADE,
  asaas_id          TEXT UNIQUE,
  -- ID da cobrança no Asaas (preenchido após integração)
  valor             NUMERIC(10,2) NOT NULL,
  status            TEXT NOT NULL DEFAULT 'pendente'
                    CHECK (status IN ('pendente', 'pago', 'vencido', 'cancelado', 'estornado')),
  tipo_cobranca     TEXT NOT NULL DEFAULT 'boleto'
                    CHECK (tipo_cobranca IN ('boleto', 'pix', 'cartao', 'manual')),
  data_vencimento   DATE NOT NULL,
  data_pagamento    DATE,
  url_boleto        TEXT,
  -- link do boleto gerado pelo Asaas
  url_pix           TEXT,
  -- QR code Pix gerado pelo Asaas
  descricao         TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_cobrancas_updated_at
  BEFORE UPDATE ON public.cobrancas
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_cobrancas_empresa    ON public.cobrancas(empresa_id);
CREATE INDEX IF NOT EXISTS idx_cobrancas_status     ON public.cobrancas(status);

-- ============================================================
-- RLS: webhooks_log e cobrancas — apenas master
-- ============================================================
ALTER TABLE public.webhooks_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cobrancas    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "master_all_webhooks" ON public.webhooks_log
  FOR ALL TO authenticated
  USING (public.is_master()) WITH CHECK (public.is_master());

CREATE POLICY "master_all_cobrancas" ON public.cobrancas
  FOR ALL TO authenticated
  USING (public.is_master()) WITH CHECK (public.is_master());

-- Owner pode VER suas próprias cobranças
CREATE POLICY "owner_ver_cobrancas" ON public.cobrancas
  FOR SELECT TO authenticated
  USING (empresa_id = public.get_my_empresa_id()
    AND public.get_my_role() = 'owner');

-- ============================================================
-- FUNÇÃO: processar webhook de pagamento (stub)
-- Quando integrar Asaas, esta função recebe o evento e
-- atualiza a assinatura automaticamente.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_processar_webhook(
  p_gateway TEXT,
  p_evento  TEXT,
  p_payload JSONB
)
RETURNS JSONB AS $$
DECLARE
  v_log_id     UUID;
  v_empresa_id UUID;
  v_asaas_id   TEXT;
BEGIN
  -- Registrar o webhook recebido
  INSERT INTO public.webhooks_log (gateway, evento, payload, status)
  VALUES (p_gateway, p_evento, p_payload, 'recebido')
  RETURNING id INTO v_log_id;

  -- ── STUB: lógica de processamento futura ──────────────────
  -- Quando integrar com Asaas, adicionar aqui:
  --
  -- 1. Extrair asaas_id do payload
  --    v_asaas_id := p_payload->>'id';
  --
  -- 2. Buscar cobrança correspondente
  --    SELECT empresa_id INTO v_empresa_id
  --    FROM cobrancas WHERE asaas_id = v_asaas_id;
  --
  -- 3. Se evento = 'PAYMENT_RECEIVED':
  --    UPDATE assinaturas SET status='ativo',
  --      data_vencimento = data_vencimento + INTERVAL '1 month'
  --    WHERE empresa_id = v_empresa_id;
  --
  -- 4. Se evento = 'PAYMENT_OVERDUE':
  --    UPDATE assinaturas SET status='vencido'
  --    WHERE empresa_id = v_empresa_id;
  --
  -- 5. Marcar webhook como processado
  -- ─────────────────────────────────────────────────────────

  -- Por ora, apenas marcar como ignorado (integracao futura)
  UPDATE public.webhooks_log
  SET status = 'ignorado',
      processed_at = NOW()
  WHERE id = v_log_id;

  RETURN jsonb_build_object(
    'received', TRUE,
    'log_id', v_log_id,
    'nota', 'Webhook registrado. Integração com Asaas pendente de implementação.'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- VIEW: metricas_plataforma (apenas master)
-- Visão consolidada de todas as empresas para o Admin Master.
-- ============================================================
CREATE OR REPLACE VIEW public.v_metricas_plataforma AS
SELECT
  e.id                              AS empresa_id,
  e.nome_fantasia,
  e.email,
  e.status                          AS empresa_status,
  a.plano,
  a.status                          AS assinatura_status,
  a.data_vencimento,
  a.valor                           AS valor_plano,
  (SELECT COUNT(*) FROM public.profiles p WHERE p.empresa_id = e.id)
                                    AS total_usuarios,
  (SELECT COUNT(*) FROM public.ordens_servico o WHERE o.empresa_id = e.id)
                                    AS ordens_ativas,
  (SELECT COUNT(*) FROM public.historico h WHERE h.empresa_id = e.id)
                                    AS total_atendimentos,
  (SELECT COALESCE(SUM(h.value),0) FROM public.historico h WHERE h.empresa_id = e.id)
                                    AS faturamento_total_plataforma,
  e.data_criacao
FROM public.empresas e
LEFT JOIN public.assinaturas a ON a.empresa_id = e.id;

-- Revogar acesso direto — apenas funções com SECURITY DEFINER acessam
REVOKE ALL ON public.v_metricas_plataforma FROM PUBLIC;
GRANT SELECT ON public.v_metricas_plataforma TO authenticated;

-- ============================================================
-- FIM DA MIGRAÇÃO 004
-- Próximo passo: execute seed.sql
-- ============================================================
