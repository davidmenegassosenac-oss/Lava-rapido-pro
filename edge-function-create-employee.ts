// ============================================================
// EDGE FUNCTION: create-employee
// Lava Rápido SaaS
//
// Resolve a vulnerabilidade de "sequestro de sessão": antes,
// o owner chamava sb.auth.signUp() diretamente do client, o que
// troca a sessão ativa do navegador para o usuário recém-criado.
//
// Esta função roda no servidor (Deno runtime do Supabase) usando
// a SERVICE ROLE KEY, que nunca é exposta ao navegador. Ela cria
// o usuário via Admin API (admin.createUser), que NÃO afeta a
// sessão de quem chamou a função.
//
// Também aplica a verificação de limite de plano (max_usuarios)
// ANTES de criar o usuário — fechando a segunda vulnerabilidade
// (limites de plano nunca verificados).
//
// Deploy:
//   supabase functions deploy create-employee
//
// Variáveis de ambiente necessárias (configradas automaticamente
// pelo Supabase ao fazer deploy, mas confirme em Project Settings
// → Edge Functions → Secrets):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { email, password, name, role, empresa_id } = await req.json();

    if (!email || !password || !name || !empresa_id) {
      return new Response(
        JSON.stringify({ success: false, message: 'Dados obrigatórios faltando.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ── Client com privilégio de service role (servidor apenas) ──────────
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL'),
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    // ── Client com o token de quem chamou, para validar autorização ──────
    const authHeader = req.headers.get('Authorization');
    const supabaseCaller = createClient(
      Deno.env.get('SUPABASE_URL'),
      Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
      { global: { headers: { Authorization: authHeader ?? '' } } }
    );

    // ── 1. Verificar quem está chamando é realmente owner da empresa alvo ─
    const { data: callerUser, error: callerErr } = await supabaseCaller.auth.getUser();
    if (callerErr || !callerUser?.user) {
      return new Response(
        JSON.stringify({ success: false, message: 'Não autenticado.' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data: callerProfile } = await supabaseAdmin
      .from('profiles')
      .select('role, empresa_id')
      .eq('id', callerUser.user.id)
      .single();

    const isMaster = callerProfile?.role === 'master';
    const isOwnerOfTarget = callerProfile?.role === 'owner' && callerProfile?.empresa_id === empresa_id;

    if (!isMaster && !isOwnerOfTarget) {
      return new Response(
        JSON.stringify({ success: false, message: 'Sem permissão para criar usuários nesta empresa.' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ── 2. Verificar limite de plano (max_usuarios) ANTES de criar ───────
    const { data: assinatura } = await supabaseAdmin
      .from('assinaturas')
      .select('plano')
      .eq('empresa_id', empresa_id)
      .single();

    const plano = assinatura?.plano || 'trial';

    const { data: planoConfig } = await supabaseAdmin
      .from('planos_config')
      .select('max_usuarios, nome_exibicao')
      .eq('plano', plano)
      .single();

    const { count: totalUsuariosAtivos } = await supabaseAdmin
      .from('profiles')
      .select('id', { count: 'exact', head: true })
      .eq('empresa_id', empresa_id)
      .eq('ativo', true);

    const limite = planoConfig?.max_usuarios ?? 2;

    if ((totalUsuariosAtivos ?? 0) >= limite) {
      return new Response(
        JSON.stringify({
          success: false,
          message: `Limite de ${limite} usuário(s) do plano "${planoConfig?.nome_exibicao || plano}" atingido. Faça upgrade do plano para adicionar mais funcionários.`,
          limit_reached: true,
        }),
        { status: 422, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ── 3. Criar usuário via Admin API — NÃO afeta sessão do chamador ────
    const { data: newUser, error: createErr } = await supabaseAdmin.auth.admin.createUser({
      email: email.trim().toLowerCase(),
      password,
      email_confirm: true, // já confirma, pois o projeto desativou confirmação por e-mail
      user_metadata: { name: name.trim(), role },
    });

    if (createErr) {
      return new Response(
        JSON.stringify({ success: false, message: createErr.message }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ── 4. Vincular o novo usuário à empresa ──────────────────────────────
    const { error: updateErr } = await supabaseAdmin
      .from('profiles')
      .update({ empresa_id, role, name: name.trim(), ativo: true })
      .eq('id', newUser.user.id);

    if (updateErr) {
      // Rollback: remove o usuário recém-criado para não deixar lixo órfão
      await supabaseAdmin.auth.admin.deleteUser(newUser.user.id);
      return new Response(
        JSON.stringify({ success: false, message: 'Erro ao vincular usuário à empresa.' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, user_id: newUser.user.id }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (e) {
    return new Response(
      JSON.stringify({ success: false, message: e.message || 'Erro interno.' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
