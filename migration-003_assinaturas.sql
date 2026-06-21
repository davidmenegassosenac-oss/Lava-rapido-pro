-- ============================================================
-- MIGRAÇÃO 003 — SISTEMA DE ASSINATURAS
-- Lava Rápido SaaS
-- Execute APÓS 002_rls_policies.sql
-- ============================================================

-- ============================================================
-- TABELA: assinaturas
-- Uma assinatura por empresa. Controla acesso ao sistema.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.assinaturas (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  empresa_id        UUID NOT NULL UNIQUE REFERENCES public.empresas(id) ON DELETE CASCADE,
  plano             TEXT NOT NULL DEFAULT 'trial'
                    CHECK (plano IN ('trial', 'basico', 'profissional', 'enterprise')),
  status            TEXT NOT NULL DEFAULT 'trial'
                    CHECK (status IN ('trial', 'ativo', 'vencido', 'suspenso', 'cancelado')),
  valor             NUMERIC(10,2) NOT NULL DEFAULT 0,
  data_inicio       DATE NOT NULL DEFAULT CURRENT_DATE,
  data_vencimento   DATE NOT NULL DEFAULT (CURRENT_DATE + INTERVAL '14 days'),
  -- 14 dias de trial gratuito
  data_pagamento    DATE,
  -- último pagamento confirmado
  trial_usado       BOOLEAN NOT NULL DEFAULT FALSE,
  observacoes       TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_assinaturas_updated_at
  BEFORE UPDATE ON public.assinaturas
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_assinaturas_empresa ON public.assinaturas(empresa_id);
CREATE INDEX IF NOT EXISTS idx_assinaturas_status  ON public.assinaturas(status);

-- ============================================================
-- TABELA: planos_config
-- Limites e preços por plano. Facilita ajuste sem código.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.planos_config (
  plano            TEXT PRIMARY KEY,
  nome_exibicao    TEXT NOT NULL,
  valor_mensal     NUMERIC(10,2) NOT NULL DEFAULT 0,
  max_usuarios     INTEGER NOT NULL DEFAULT 2,
  max_ordens_mes   INTEGER NOT NULL DEFAULT 100,
  funcionalidades  JSONB NOT NULL DEFAULT '[]',
  ativo            BOOLEAN NOT NULL DEFAULT TRUE
);

-- Inserir planos padrão
INSERT INTO public.planos_config (plano, nome_exibicao, valor_mensal, max_usuarios, max_ordens_mes, funcionalidades)
VALUES
  ('trial',        'Trial Gratuito',  0,     2,    50,
   '["fila", "historico", "crm", "suporte"]'),
  ('basico',       'Básico',          49.90, 3,    200,
   '["fila", "historico", "crm", "suporte", "caixa_simples"]'),
  ('profissional', 'Profissional',    89.90, 10,   1000,
   '["fila", "historico", "crm", "suporte", "caixa_completo", "relatorios", "equipe"]'),
  ('enterprise',   'Enterprise',      149.90, 999, 999999,
   '["fila", "historico", "crm", "suporte", "caixa_completo", "relatorios", "equipe", "api", "whitelabel"]')
ON CONFLICT (plano) DO NOTHING;

-- ============================================================
-- RLS: assinaturas
-- Master vê todas. Owner vê apenas a da própria empresa.
-- ============================================================
ALTER TABLE public.assinaturas ENABLE ROW LEVEL SECURITY;

CREATE POLICY "master_all_assinaturas" ON public.assinaturas
  FOR ALL TO authenticated
  USING (public.is_master())
  WITH CHECK (public.is_master());

CREATE POLICY "owner_ver_propria_assinatura" ON public.assinaturas
  FOR SELECT TO authenticated
  USING (empresa_id = public.get_my_empresa_id());

-- planos_config: todos leem, ninguém escreve (exceto master)
ALTER TABLE public.planos_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "todos_leem_planos" ON public.planos_config
  FOR SELECT TO authenticated USING (TRUE);

CREATE POLICY "master_manage_planos" ON public.planos_config
  FOR ALL TO authenticated
  USING (public.is_master())
  WITH CHECK (public.is_master());

-- ============================================================
-- FUNÇÃO: verificar se assinatura está ativa
-- Retorna TRUE se pode usar o sistema, FALSE se bloqueado.
-- Chamada no frontend após login.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_assinatura_valida(p_empresa_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_ass public.assinaturas%ROWTYPE;
  v_dias_restantes INTEGER;
BEGIN
  SELECT * INTO v_ass
  FROM public.assinaturas
  WHERE empresa_id = p_empresa_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'valida', FALSE,
      'status', 'sem_assinatura',
      'mensagem', 'Nenhuma assinatura encontrada para esta empresa.'
    );
  END IF;

  v_dias_restantes := (v_ass.data_vencimento - CURRENT_DATE);

  -- Trial ativo
  IF v_ass.status = 'trial' AND CURRENT_DATE <= v_ass.data_vencimento THEN
    RETURN jsonb_build_object(
      'valida', TRUE,
      'status', 'trial',
      'plano', v_ass.plano,
      'dias_restantes', v_dias_restantes,
      'mensagem', 'Trial ativo. ' || v_dias_restantes || ' dias restantes.'
    );
  END IF;

  -- Assinatura ativa
  IF v_ass.status = 'ativo' AND CURRENT_DATE <= v_ass.data_vencimento THEN
    RETURN jsonb_build_object(
      'valida', TRUE,
      'status', 'ativo',
      'plano', v_ass.plano,
      'dias_restantes', v_dias_restantes,
      'mensagem', 'Assinatura ativa.'
    );
  END IF;

  -- Trial vencido
  IF v_ass.status = 'trial' AND CURRENT_DATE > v_ass.data_vencimento THEN
    -- Atualiza status automaticamente
    UPDATE public.assinaturas SET status = 'vencido' WHERE id = v_ass.id;
    RETURN jsonb_build_object(
      'valida', FALSE,
      'status', 'trial_vencido',
      'mensagem', 'Período de trial encerrado. Assine um plano para continuar.'
    );
  END IF;

  -- Assinatura vencida
  IF CURRENT_DATE > v_ass.data_vencimento THEN
    UPDATE public.assinaturas SET status = 'vencido' WHERE id = v_ass.id;
    RETURN jsonb_build_object(
      'valida', FALSE,
      'status', 'vencido',
      'mensagem', 'Assinatura vencida. Renove para continuar.'
    );
  END IF;

  -- Suspenso ou cancelado
  RETURN jsonb_build_object(
    'valida', FALSE,
    'status', v_ass.status,
    'mensagem', 'Conta suspensa ou cancelada. Entre em contato com o suporte.'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- FUNÇÃO: criar empresa + assinatura trial em uma transação
-- Chamada pelo frontend no cadastro de nova empresa.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_criar_empresa(
  p_nome_fantasia  TEXT,
  p_email          TEXT,
  p_telefone       TEXT DEFAULT NULL,
  p_cnpj           TEXT DEFAULT NULL,
  p_razao_social   TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_empresa_id UUID;
BEGIN
  -- Criar empresa
  INSERT INTO public.empresas (nome_fantasia, email, telefone, cnpj, razao_social)
  VALUES (p_nome_fantasia, p_email, p_telefone, p_cnpj, p_razao_social)
  RETURNING id INTO v_empresa_id;

  -- Criar assinatura trial (14 dias)
  INSERT INTO public.assinaturas (empresa_id, plano, status, valor, data_vencimento)
  VALUES (v_empresa_id, 'trial', 'trial', 0, CURRENT_DATE + INTERVAL '14 days');

  -- Inserir serviços padrão do catálogo
  INSERT INTO public.servicos_catalogo (empresa_id, nome, valor) VALUES
    (v_empresa_id, 'Lavagem Simples',      30.00),
    (v_empresa_id, 'Lavagem Completa',     50.00),
    (v_empresa_id, 'Polimento',            120.00),
    (v_empresa_id, 'Higienização Interna', 90.00),
    (v_empresa_id, 'Enceramento',          80.00);

  RETURN jsonb_build_object(
    'success', TRUE,
    'empresa_id', v_empresa_id,
    'mensagem', 'Empresa criada com 14 dias de trial gratuito.'
  );

EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object(
    'success', FALSE,
    'mensagem', 'E-mail ou CNPJ já cadastrado.'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- FIM DA MIGRAÇÃO 003
-- Próximo passo: execute 004_webhooks_prep.sql
-- ============================================================
