-- ============================================================
-- MIGRAÇÃO 001 — ESTRUTURA MULTI-TENANT
-- Lava Rápido SaaS
-- Execute este arquivo PRIMEIRO no SQL Editor do Supabase
-- ============================================================

-- Habilitar extensão de UUID (já vem ativa no Supabase, mas garantindo)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- TABELA: empresas
-- Cada lava-jato cadastrado na plataforma é uma empresa.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.empresas (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nome_fantasia    TEXT NOT NULL,
  razao_social     TEXT,
  cnpj             TEXT UNIQUE,
  telefone         TEXT,
  email            TEXT UNIQUE NOT NULL,
  logo_url         TEXT,
  status           TEXT NOT NULL DEFAULT 'ativo'
                   CHECK (status IN ('ativo', 'suspenso', 'cancelado')),
  plano            TEXT NOT NULL DEFAULT 'trial'
                   CHECK (plano IN ('trial', 'basico', 'profissional', 'enterprise')),
  data_criacao     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TABELA: profiles
-- Estende auth.users do Supabase Auth.
-- Cada usuário pertence a uma empresa (exceto master).
-- ============================================================
CREATE TABLE IF NOT EXISTS public.profiles (
  id           UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  empresa_id   UUID REFERENCES public.empresas(id) ON DELETE SET NULL,
  name         TEXT NOT NULL,
  role         TEXT NOT NULL DEFAULT 'employee'
               CHECK (role IN ('master', 'owner', 'employee')),
  ativo        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TABELA: ordens_servico
-- Fila de veículos em atendimento (ativo/em andamento).
-- ============================================================
CREATE TABLE IF NOT EXISTS public.ordens_servico (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  empresa_id   UUID NOT NULL REFERENCES public.empresas(id) ON DELETE CASCADE,
  plate        TEXT NOT NULL,
  model        TEXT NOT NULL,
  client       TEXT NOT NULL,
  phone        TEXT NOT NULL,
  type         TEXT NOT NULL,
  value        NUMERIC(10,2) NOT NULL DEFAULT 0,
  status       TEXT NOT NULL DEFAULT 'Aguardando'
               CHECK (status IN ('Aguardando', 'Lavando', 'Concluído', 'Pago')),
  color        TEXT NOT NULL DEFAULT '#0ea5e9',
  observacoes  TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ
);

-- ============================================================
-- TABELA: historico
-- Ordens finalizadas (status = Pago) são movidas aqui.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.historico (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  empresa_id   UUID NOT NULL REFERENCES public.empresas(id) ON DELETE CASCADE,
  ordem_id     UUID REFERENCES public.ordens_servico(id) ON DELETE SET NULL,
  plate        TEXT NOT NULL,
  model        TEXT NOT NULL,
  client       TEXT NOT NULL,
  phone        TEXT NOT NULL,
  type         TEXT NOT NULL,
  value        NUMERIC(10,2) NOT NULL DEFAULT 0,
  status       TEXT NOT NULL DEFAULT 'Pago',
  color        TEXT NOT NULL DEFAULT '#0ea5e9',
  observacoes  TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TABELA: caixa_movimentos
-- Entradas e saídas financeiras da empresa.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.caixa_movimentos (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  empresa_id   UUID NOT NULL REFERENCES public.empresas(id) ON DELETE CASCADE,
  tipo         TEXT NOT NULL CHECK (tipo IN ('entrada', 'saida')),
  categoria    TEXT NOT NULL,
  -- Entradas: lavagem, detalhamento, produto_venda, outro
  -- Saídas:   produto_compra, despesa, salario, manutencao, outro
  descricao    TEXT,
  valor        NUMERIC(10,2) NOT NULL DEFAULT 0,
  ordem_id     UUID REFERENCES public.historico(id) ON DELETE SET NULL,
  -- referência opcional à ordem que gerou esta entrada
  data         DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TABELA: servicos_catalogo
-- Tipos de serviços e preços padrão por empresa.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.servicos_catalogo (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  empresa_id   UUID NOT NULL REFERENCES public.empresas(id) ON DELETE CASCADE,
  nome         TEXT NOT NULL,
  valor        NUMERIC(10,2) NOT NULL DEFAULT 0,
  ativo        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TRIGGERS: updated_at automático
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_empresas_updated_at
  BEFORE UPDATE ON public.empresas
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_ordens_updated_at
  BEFORE UPDATE ON public.ordens_servico
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- ÍNDICES: performance em consultas por empresa
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_ordens_empresa    ON public.ordens_servico(empresa_id);
CREATE INDEX IF NOT EXISTS idx_ordens_status     ON public.ordens_servico(status);
CREATE INDEX IF NOT EXISTS idx_historico_empresa ON public.historico(empresa_id);
CREATE INDEX IF NOT EXISTS idx_historico_phone   ON public.historico(phone);
CREATE INDEX IF NOT EXISTS idx_caixa_empresa     ON public.caixa_movimentos(empresa_id);
CREATE INDEX IF NOT EXISTS idx_caixa_data        ON public.caixa_movimentos(data);
CREATE INDEX IF NOT EXISTS idx_profiles_empresa  ON public.profiles(empresa_id);

-- ============================================================
-- FIM DA MIGRAÇÃO 001
-- Próximo passo: execute 002_rls_policies.sql
-- ============================================================
