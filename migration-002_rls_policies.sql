-- ============================================================
-- MIGRAÇÃO 002 — ROW LEVEL SECURITY (RLS)
-- Lava Rápido SaaS
-- Execute APÓS 001_multitenancy.sql
-- CRÍTICO: garante isolamento total entre empresas
-- ============================================================

-- ============================================================
-- FUNÇÃO AUXILIAR: retorna empresa_id do usuário logado
-- Usada por todas as políticas de RLS abaixo.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_empresa_id()
RETURNS UUID AS $$
  SELECT empresa_id
  FROM public.profiles
  WHERE id = auth.uid()
  LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ============================================================
-- FUNÇÃO AUXILIAR: retorna role do usuário logado
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS TEXT AS $$
  SELECT role
  FROM public.profiles
  WHERE id = auth.uid()
  LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ============================================================
-- FUNÇÃO AUXILIAR: verifica se usuário é master
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_master()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'master'
  );
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ============================================================
-- RLS: TABELA empresas
-- Master vê tudo. Owner/Employee veem apenas a própria empresa.
-- ============================================================
ALTER TABLE public.empresas ENABLE ROW LEVEL SECURITY;

CREATE POLICY "master_all_empresas" ON public.empresas
  FOR ALL
  TO authenticated
  USING (public.is_master())
  WITH CHECK (public.is_master());

CREATE POLICY "empresa_ver_propria" ON public.empresas
  FOR SELECT
  TO authenticated
  USING (id = public.get_my_empresa_id());

-- ============================================================
-- RLS: TABELA profiles
-- Master vê todos. Usuários veem apenas perfis da própria empresa.
-- Owner pode gerenciar usuários da sua empresa.
-- ============================================================
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Master acessa tudo
CREATE POLICY "master_all_profiles" ON public.profiles
  FOR ALL
  TO authenticated
  USING (public.is_master())
  WITH CHECK (public.is_master());

-- Usuário vê perfis da mesma empresa
CREATE POLICY "empresa_ver_profiles" ON public.profiles
  FOR SELECT
  TO authenticated
  USING (empresa_id = public.get_my_empresa_id());

-- Owner pode inserir/atualizar/deletar usuários da própria empresa
CREATE POLICY "owner_manage_profiles" ON public.profiles
  FOR ALL
  TO authenticated
  USING (
    empresa_id = public.get_my_empresa_id()
    AND public.get_my_role() IN ('owner', 'master')
  )
  WITH CHECK (
    empresa_id = public.get_my_empresa_id()
    AND public.get_my_role() IN ('owner', 'master')
  );

-- Usuário sempre pode ler o próprio perfil
CREATE POLICY "user_own_profile" ON public.profiles
  FOR SELECT
  TO authenticated
  USING (id = auth.uid());

-- ============================================================
-- RLS: TABELA ordens_servico
-- Todos os roles veem e operam apenas dados da própria empresa.
-- ============================================================
ALTER TABLE public.ordens_servico ENABLE ROW LEVEL SECURITY;

CREATE POLICY "master_all_ordens" ON public.ordens_servico
  FOR ALL TO authenticated
  USING (public.is_master())
  WITH CHECK (public.is_master());

CREATE POLICY "empresa_all_ordens" ON public.ordens_servico
  FOR ALL TO authenticated
  USING (empresa_id = public.get_my_empresa_id())
  WITH CHECK (empresa_id = public.get_my_empresa_id());

-- ============================================================
-- RLS: TABELA historico
-- Todos os roles da empresa leem. Apenas sistema insere (via função).
-- ============================================================
ALTER TABLE public.historico ENABLE ROW LEVEL SECURITY;

CREATE POLICY "master_all_historico" ON public.historico
  FOR ALL TO authenticated
  USING (public.is_master())
  WITH CHECK (public.is_master());

CREATE POLICY "empresa_all_historico" ON public.historico
  FOR ALL TO authenticated
  USING (empresa_id = public.get_my_empresa_id())
  WITH CHECK (empresa_id = public.get_my_empresa_id());

-- ============================================================
-- RLS: TABELA caixa_movimentos
-- Apenas owner e master têm acesso financeiro.
-- ============================================================
ALTER TABLE public.caixa_movimentos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "master_all_caixa" ON public.caixa_movimentos
  FOR ALL TO authenticated
  USING (public.is_master())
  WITH CHECK (public.is_master());

CREATE POLICY "owner_caixa_empresa" ON public.caixa_movimentos
  FOR ALL TO authenticated
  USING (
    empresa_id = public.get_my_empresa_id()
    AND public.get_my_role() IN ('owner', 'master')
  )
  WITH CHECK (
    empresa_id = public.get_my_empresa_id()
    AND public.get_my_role() IN ('owner', 'master')
  );

-- ============================================================
-- RLS: TABELA servicos_catalogo
-- Owner gerencia. Employee apenas lê para preencher formulário.
-- ============================================================
ALTER TABLE public.servicos_catalogo ENABLE ROW LEVEL SECURITY;

CREATE POLICY "master_all_servicos" ON public.servicos_catalogo
  FOR ALL TO authenticated
  USING (public.is_master())
  WITH CHECK (public.is_master());

CREATE POLICY "empresa_read_servicos" ON public.servicos_catalogo
  FOR SELECT TO authenticated
  USING (empresa_id = public.get_my_empresa_id());

CREATE POLICY "owner_manage_servicos" ON public.servicos_catalogo
  FOR ALL TO authenticated
  USING (
    empresa_id = public.get_my_empresa_id()
    AND public.get_my_role() = 'owner'
  )
  WITH CHECK (
    empresa_id = public.get_my_empresa_id()
    AND public.get_my_role() = 'owner'
  );

-- ============================================================
-- FUNÇÃO: mover ordem para histórico ao marcar como Pago
-- Executada via trigger automático — nenhuma empresa pode burlar.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_ordem_paga()
RETURNS TRIGGER AS $$
BEGIN
  -- Quando status muda para 'Pago', copiar para histórico
  IF NEW.status = 'Pago' AND OLD.status <> 'Pago' THEN

    INSERT INTO public.historico (
      empresa_id, ordem_id, plate, model, client,
      phone, type, value, status, color, observacoes, completed_at
    ) VALUES (
      NEW.empresa_id, NEW.id, NEW.plate, NEW.model, NEW.client,
      NEW.phone, NEW.type, NEW.value, 'Pago', NEW.color,
      NEW.observacoes, NOW()
    );

    -- Registrar entrada no caixa automaticamente
    INSERT INTO public.caixa_movimentos (
      empresa_id, tipo, categoria, descricao, valor, data
    ) VALUES (
      NEW.empresa_id, 'entrada', 'lavagem',
      NEW.type || ' — ' || NEW.model || ' (' || NEW.plate || ')',
      NEW.value, CURRENT_DATE
    );

    -- Remover da fila ativa
    DELETE FROM public.ordens_servico WHERE id = NEW.id;

    RETURN NULL; -- cancela o UPDATE pois deletou a linha
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_ordem_paga
  BEFORE UPDATE OF status ON public.ordens_servico
  FOR EACH ROW EXECUTE FUNCTION public.fn_ordem_paga();

-- ============================================================
-- FUNÇÃO: criar profile automaticamente após signup
-- Dispara quando um novo usuário é criado no Supabase Auth.
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  -- Tenta criar profile básico.
  -- empresa_id e role serão definidos pelo fluxo de onboarding.
  INSERT INTO public.profiles (id, name, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'role', 'employee')
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER trg_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.fn_handle_new_user();

-- ============================================================
-- FIM DA MIGRAÇÃO 002
-- Próximo passo: execute 003_assinaturas.sql
-- ============================================================
