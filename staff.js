/* staff.js | Equipa, níveis de acesso e fichas (RH)
   Usado pelo painel (PostAngola.html) e pelo rh.html, para as regras serem as mesmas nos dois.
   IMPORTANTE: quem vê o quê é decidido pela BASE DE DADOS (regras RLS do supabase_rh.sql).
   Este ficheiro só desenha o que a base de dados devolve e esconde botões sem permissão. */
(function () {
  "use strict";

  var LEVELS = { N0: 0, N1: 10, N2: 20, B1: 60, B2: 70, B10: 80, M1: 90, M100: 100, C1: 200 };
  var LABELS = {
    N0: "Leitor", N1: "Redator", N2: "Editor-chefe", B1: "Técnico de RH", B2: "Diretor de RH",
    B10: "Diretor-geral", M1: "Administrador", M100: "Super administrador", C1: "Proprietário"
  };
  var ASSIGNABLE = ["N0", "N1", "N2", "B1", "B2", "B10", "M1", "M100"];
  var DEPTS = ["Redação", "RH", "Comercial", "Técnico", "Direção"];
  var CATS = ["Efetivo", "Estagiário", "Freelancer", "Colaborador"];
  var RH_ROLES = [["funcionario", "Funcionário"], ["tecnico_rh", "Técnico de RH"], ["director_rh", "Diretor de RH"], ["ceo", "Proprietário"]];
  var ACTIONS = {
    article_published: "Notícia publicada", article_submitted: "Notícia enviada para aprovação",
    article_approved: "Notícia aprovada", article_returned: "Notícia devolvida ao autor",
    article_unpublished: "Notícia despublicada", article_edited: "Notícia editada",
    article_featured: "Notícia destacada", article_unfeatured: "Destaque retirado",
    article_deleted: "Notícia apagada", article_reposted: "Notícia repostada", article_draft: "Rascunho criado",
    set_access: "Nível de acesso alterado", set_status: "Estado da conta alterado", staff_updated: "Ficha atualizada",
    invite_created: "Convite criado", invite_approved: "Convite aprovado", invite_rejected: "Convite rejeitado",
    invite_applied: "Convite aplicado (conta ligada)", profile_approved: "Perfil aprovado", profile_rejected: "Perfil rejeitado"
  };

  function levelOf(code) { return Object.prototype.hasOwnProperty.call(LEVELS, code) ? LEVELS[code] : 0; }
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function fmtDate(v) {
    if (!v) return "";
    var d = new Date(v);
    return isNaN(d) ? "" : d.toLocaleString("pt-PT", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
  }
  function fmtDay(v) {
    if (!v) return "";
    var d = new Date(v + (String(v).length === 10 ? "T00:00:00" : ""));
    return isNaN(d) ? esc(v) : d.toLocaleDateString("pt-PT", { day: "2-digit", month: "long", year: "numeric" });
  }

  /* Espelho das regras da base de dados, só para o ecrã. A base de dados volta a verificar tudo. */
  function perms(me) {
    var c = me.access_code || "N0", l = levelOf(c);
    return {
      code: c, level: l,
      panel: l >= 10, publish: l >= 20, ads: l >= 20,
      viewAll: l >= 80 || c === "B1" || c === "B2",
      viewDept: l >= 20,
      editStaff: c === "B1" || c === "B2" || l >= 90,
      setAccess: l >= 90,
      approveInvites: c === "C1",
      audit: l >= 60
    };
  }

  async function loadMe(sb) {
    var s = await sb.auth.getSession();
    var session = s && s.data && s.data.session;
    if (!session) return { error: "login" };
    var r = await sb.from("profiles")
      .select("id,full_name,email,role,access_code,department,rh_role,employee_category,status,approval_status")
      .eq("id", session.user.id).maybeSingle();
    if (r.error) {
      return { error: /column|schema cache|does not exist/i.test(r.error.message || "") ? "migration" : "profile", detail: r.error.message };
    }
    if (!r.data) return { error: "profile" };
    var p = r.data, active = p.status === "ativo" && p.approval_status === "aprovado";
    var me = Object.assign({}, p, { name: p.full_name || session.user.email, active: active, level: active ? levelOf(p.access_code) : 0 });
    return { me: me, session: session };
  }

  /* ------------------------------------------------------------------ */
  var cssDone = false;
  function injectCss() {
    if (cssDone) return; cssDone = true;
    var st = document.createElement("style");
    st.textContent =
      ".st-me{display:flex;gap:16px;align-items:flex-start;flex-wrap:wrap}" +
      ".st-me ul{margin:8px 0 0;padding-left:18px;color:var(--muted,#6B645C);font-size:13.5px}" +
      ".st-me li{margin-bottom:3px}" +
      ".st-badge{display:inline-block;background:#121212;color:#fff;border-radius:999px;padding:3px 12px;font-weight:700;font-size:12.5px}" +
      ".st-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;align-items:start;margin-top:16px}" +
      ".st-card{margin-top:16px}" +
      ".st-ind{font-weight:700}.st-up{color:#16a34a}.st-down{color:#d97706}" +
      ".st-row-actions{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}" +
      ".li .t span.pill{display:inline-block;font-size:12px;font-weight:700;color:var(--muted,#6B645C)}" +
      ".li .t span.pill.warn{color:var(--warn,#8A5A00)}.li .t span.pill.ok{color:var(--ok,#1B7F4B)}" +
      ".st-dialog{border:0;border-radius:18px;padding:0;width:min(640px,calc(100% - 24px));max-height:90vh;background:var(--surface,#fff);color:var(--text,#16120F);box-shadow:0 24px 80px rgba(0,0,0,.4)}" +
      ".st-dialog::backdrop{background:rgba(10,8,6,.55)}" +
      ".st-dlg{padding:22px;max-height:88vh;overflow:auto}" +
      ".st-dlg h3{font-size:20px;margin:0 0 4px}" +
      ".st-sub{color:var(--muted,#6B645C);font-size:13px;margin-bottom:12px}" +
      ".st-r{display:grid;grid-template-columns:150px 1fr;gap:10px;padding:8px 0;border-bottom:1px solid var(--border,#E3DED6);font-size:14px}" +
      ".st-r b{color:var(--muted,#6B645C);font-weight:600}" +
      ".st-r span{word-break:break-word}" +
      ".st-h{font-size:12.5px;font-weight:700;color:var(--muted,#6B645C);margin:18px 0 4px}" +
      ".st-lock{background:var(--warn-bg,#FFF3D6);color:var(--warn,#8A5A00);border-radius:10px;padding:12px 14px;font-size:13.5px;margin-top:10px}" +
      ".st-admin{margin-top:16px;border-top:1px solid var(--border,#E3DED6);padding-top:14px;display:flex;flex-direction:column;gap:12px}" +
      ".st-inline{display:flex;gap:8px;align-items:center;flex-wrap:wrap}" +
      ".st-inline select{width:auto;margin:0;min-width:180px}" +
      ".st-form{display:grid;grid-template-columns:1fr 1fr;gap:10px 12px}" +
      ".st-form .full{grid-column:1/-1}" +
      ".st-form label{display:block;font-size:12.5px;font-weight:600;margin-bottom:4px}" +
      ".st-form input,.st-form select,.st-form textarea{width:100%;margin:0}" +
      ".st-foot{display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap;margin-top:16px}" +
      "@media (max-width:760px){.st-grid{grid-template-columns:1fr}.st-r{grid-template-columns:1fr;gap:2px}.st-form{grid-template-columns:1fr}}";
    document.head.appendChild(st);
  }

  /* ------------------------------------------------------------------ */
  function mount(root, opts) {
    injectCss();
    var sb = opts.sb, me = opts.me, toast = opts.toast || function (m) { alert(m); };
    var full = opts.mode === "full";
    var P = perms(me);
    var rows = [], invites = [], audit = [], dialog = null, names = {};

    root.innerHTML = '<div class="empty">A carregar…</div>';

    async function load() {
      var calls = [
        sb.from("v_performance").select("*").order("full_name"),
        P.viewAll ? sb.from("staff_invites").select("*").in("status", ["pendente", "aprovado"]).order("created_at", { ascending: false }) : Promise.resolve({ data: [] }),
        P.audit ? sb.from("audit_logs").select("*").order("created_at", { ascending: false }).limit(25) : Promise.resolve({ data: [] })
      ];
      var res = await Promise.all(calls);
      if (res[0].error) {
        root.innerHTML = '<div class="notice">Não foi possível carregar a equipa: ' + esc(res[0].error.message) +
          '<br>Já correu o ficheiro <b>supabase_rh.sql</b> no Supabase?</div>';
        return false;
      }
      rows = res[0].data || []; invites = res[1].data || []; audit = res[2].data || [];
      names = {}; rows.forEach(function (r) { names[r.id] = r.full_name; });
      return true;
    }

    function scopeText() {
      if (P.viewAll) return "toda a equipa";
      if (P.viewDept) return "a equipa do seu departamento (" + esc(me.department || "—") + ")";
      return "apenas o seu perfil";
    }

    function meCard() {
      var l = [];
      l.push("Vê: " + scopeText() + ".");
      l.push(P.viewAll ? "Dados pessoais (NIF, morada, contacto): de todos." : "Dados pessoais (NIF, morada, contacto): só os seus.");
      l.push(P.publish ? "Notícias: publica, edita, aprova pendentes e reposta nas redes." : "Notícias: cria e envia para aprovação do editor-chefe.");
      if (P.editStaff) l.push("Edita fichas e convida funcionários.");
      if (P.setAccess) l.push("Altera níveis de acesso (abaixo do seu).");
      if (P.approveInvites) l.push("Aprova convites e perfis pendentes.");
      return '<div class="card st-me"><div><span class="st-badge">' + esc(P.code) + " · " + esc(LABELS[P.code] || "") + "</span>" +
        '<div class="sub" style="margin-top:6px">' + esc(me.name || "") + " · " + esc(me.department || "") + "</div></div>" +
        '<div style="flex:1;min-width:240px"><b style="font-size:13px">O que o seu nível permite</b><ul>' +
        l.map(function (x) { return "<li>" + x + "</li>"; }).join("") + "</ul></div></div>";
    }

    function indicators() {
      var staff = rows.filter(function (r) { return r.status === "ativo"; });
      var avg = staff.length ? staff.reduce(function (s, x) { return s + (Number(x.news_month) || 0); }, 0) / staff.length : 0;
      var html = staff.map(function (p) {
        var m = Number(p.news_month) || 0, up = m >= avg;
        return '<div class="li"><div class="t">' + esc(p.full_name) + "<span>" + m + " no mês · " + (Number(p.news_week) || 0) +
          " na semana · " + (Number(p.total_published) || 0) + " no total · " +
          '<span class="st-ind ' + (up ? "st-up" : "st-down") + '" style="display:inline">' + (up ? "▲ acima" : "▼ abaixo") + " da média</span></span></div>" +
          '<span class="pill ' + (p.pending_approval > 0 ? "warn" : "") + '">' + (Number(p.pending_approval) || 0) + " pendentes</span></div>";
      }).join("") || '<div class="empty">Sem dados</div>';
      return '<div class="card"><div class="card-head"><h2>Desempenho</h2><span class="pill">Média mensal: ' + avg.toFixed(1) +
        '</span></div><div class="list">' + html + "</div></div>";
    }

    function auditCard() {
      if (!P.audit) return "";
      var html = audit.map(function (a) {
        var d = a.details || {}, extra = "";
        if (d.title) extra = " · " + esc(d.title);
        else if (d.from || d.to) extra = " · " + esc(d.from || "") + " → " + esc(d.to || "");
        else if (d.email) extra = " · " + esc(d.email);
        else if (d.status) extra = " · " + esc(d.status);
        return '<div class="li"><div class="t">' + esc(ACTIONS[a.action] || a.action) +
          "<span>" + esc(names[a.actor_id] || "Sistema") + extra + " · " + esc(fmtDate(a.created_at)) + "</span></div></div>";
      }).join("") || '<div class="empty">Sem registos</div>';
      return '<div class="card"><div class="card-head"><h2>Auditoria</h2><span class="pill">últimos 25</span></div><div class="list">' + html + "</div></div>";
    }

    function teamCard() {
      var html = rows.map(function (p) {
        var self = p.id === me.id, pend = p.approval_status === "pendente", off = p.status === "inativo";
        return '<div class="li"><div class="t">' + esc(p.full_name) + (self ? " (você)" : "") +
          ' <span class="pill">' + esc(p.access_code) + "</span>" +
          (pend ? ' <span class="pill warn">pendente</span>' : "") + (off ? ' <span class="pill">inativo</span>' : "") +
          "<span>" + esc(LABELS[p.access_code] || "") + " · " + esc(p.department || "") + " · " + esc(p.employee_category || "") +
          (p.email ? " · " + esc(p.email) : "") + "</span></div>" +
          '<div class="st-row-actions"><button class="btn sm primary" type="button" data-act="ficha" data-id="' + esc(p.id) + '">Ver ficha</button></div></div>';
      }).join("") || '<div class="empty">Sem equipa visível para o seu nível.</div>';
      return '<div class="card st-card"><div class="card-head"><h2>Equipa</h2><span class="pill">' + rows.length + " pessoa(s)</span></div>" +
        '<div class="list">' + html + "</div></div>";
    }

    function inviteForm() {
      if (!full || !P.editStaff) return "";
      var opts = ASSIGNABLE.filter(function (c) { return levelOf(c) < P.level; });
      return '<div class="card st-card"><div class="card-head"><h2>Convidar funcionário</h2></div>' +
        '<p class="sub" style="margin:0 0 12px">' + (P.approveInvites
          ? "Como proprietário, o convite fica logo aprovado."
          : "O convite fica pendente até o proprietário (C1) o aprovar.") +
        " A pessoa cria a conta no site com este email e confirma o email. O acesso aplica-se sozinho. Não há palavras-passe partilhadas.</p>" +
        '<div class="st-form" id="stInv">' +
        '<div><label>Nome completo</label><input data-f="full_name"></div>' +
        '<div><label>Email</label><input data-f="email" type="email" autocomplete="off"></div>' +
        '<div><label>Nível de acesso</label><select data-f="access_code">' + opts.map(function (c) {
          return '<option value="' + c + '"' + (c === "N1" ? " selected" : "") + ">" + c + " · " + esc(LABELS[c]) + "</option>";
        }).join("") + "</select></div>" +
        '<div><label>Departamento</label><select data-f="department">' + DEPTS.map(function (d) { return "<option>" + esc(d) + "</option>"; }).join("") + "</select></div>" +
        '<div><label>Categoria</label><select data-f="employee_category">' + CATS.map(function (d) { return "<option>" + esc(d) + "</option>"; }).join("") + "</select></div>" +
        '<div><label>Início de contrato</label><input data-f="contract_start" type="date"></div>' +
        '<div><label>Data de nascimento</label><input data-f="date_of_birth" type="date"></div>' +
        '<div><label>Contacto</label><input data-f="phone"></div>' +
        '<div><label>NIF</label><input data-f="nif"></div>' +
        '<div><label>Formação</label><input data-f="formation"></div>' +
        '<div class="full"><label>Morada</label><input data-f="address"></div>' +
        '<div class="full"><label>Notas</label><textarea data-f="notes" rows="2"></textarea></div></div>' +
        '<div class="st-foot"><button class="btn primary" type="button" data-act="invite">Criar convite</button></div></div>';
    }

    function invitesCard() {
      if (!full || !P.viewAll) return "";
      var html = invites.map(function (i) {
        var pend = i.status === "pendente";
        return '<div class="li"><div class="t">' + esc(i.full_name) + ' <span class="pill">' + esc(i.access_code) + "</span>" +
          '<span>' + esc(i.email) + " · " + esc(i.department) + " · " +
          (pend ? "à espera de aprovação do proprietário" : "aprovado: a aguardar que a pessoa crie a conta e confirme o email") + "</span></div>" +
          '<div class="st-row-actions"><span class="pill ' + (pend ? "warn" : "ok") + '">' + (pend ? "pendente" : "aprovado") + "</span>" +
          (pend && P.approveInvites
            ? '<button class="btn sm primary" type="button" data-act="inv-ok" data-id="' + esc(i.id) + '">Aprovar</button>' +
              '<button class="btn sm danger" type="button" data-act="inv-no" data-id="' + esc(i.id) + '">Rejeitar</button>' : "") +
          "</div></div>";
      }).join("") || '<div class="empty">Sem convites em aberto</div>';
      return '<div class="card st-card"><div class="card-head"><h2>Convites em aberto</h2><span class="pill">' + invites.length + "</span></div>" +
        '<div class="list">' + html + "</div></div>";
    }

    function render() {
      root.innerHTML = meCard() +
        '<div class="st-grid">' + indicators() + auditCard() + "</div>" +
        teamCard() + inviteForm() + invitesCard();
    }

    async function refresh() { if (await load()) render(); }

    /* ---------------- ficha ---------------- */
    function getDialog() {
      if (!dialog) {
        dialog = document.createElement("dialog");
        dialog.className = "st-dialog";
        document.body.appendChild(dialog);
        dialog.addEventListener("click", function (e) {
          if (e.target === dialog) { dialog.close(); return; }
          var b = e.target.closest("[data-dact]");
          if (b) onDialogAct(b);
        });
      }
      return dialog;
    }
    function row(k, v) { return '<div class="st-r"><b>' + esc(k) + "</b><span>" + (v || '<i style="color:#999">sem dados</i>') + "</span></div>"; }

    async function openFicha(id) {
      var p = rows.filter(function (r) { return r.id === id; })[0];
      if (!p) return;
      var dlg = getDialog();
      dlg.innerHTML = '<div class="st-dlg"><p>A carregar…</p></div>';
      if (!dlg.open) dlg.showModal();
      var self = p.id === me.id, canSee = self || P.viewAll, rec = null;
      if (canSee) {
        var r = await sb.from("employee_records").select("*").eq("profile_id", id).maybeSingle();
        rec = r.data || null;
      }
      renderFicha(p, rec, canSee);
    }

    function renderFicha(p, rec, canSee, editing) {
      var dlg = getDialog(), self = p.id === me.id, tl = levelOf(p.access_code);
      var canEditThis = P.editStaff && tl <= P.level;
      var canAccess = P.setAccess && !self && tl < P.level;
      var canStatus = P.editStaff && !self && tl < P.level;
      var canProfile = P.approveInvites && p.approval_status === "pendente";
      var html = '<div class="st-dlg"><h3>' + esc(p.full_name) + '</h3><div class="st-sub">' + esc(p.access_code) + " · " + esc(LABELS[p.access_code] || "") +
        (p.approval_status === "pendente" ? " · pendente de aprovação" : "") + (p.status === "inativo" ? " · conta inativa" : "") + "</div>";

      if (editing && canEditThis) {
        rec = rec || {};
        html += '<div class="st-form" id="stEdit">' +
          '<div><label>Departamento</label><select data-f="department">' + DEPTS.map(function (d) { return "<option" + (d === p.department ? " selected" : "") + ">" + esc(d) + "</option>"; }).join("") + "</select></div>" +
          '<div><label>Categoria</label><select data-f="employee_category">' + CATS.map(function (d) { return "<option" + (d === p.employee_category ? " selected" : "") + ">" + esc(d) + "</option>"; }).join("") + "</select></div>" +
          '<div><label>Função de RH</label><select data-f="rh_role">' + RH_ROLES.map(function (d) { return '<option value="' + d[0] + '"' + (d[0] === p.rh_role ? " selected" : "") + ">" + esc(d[1]) + "</option>"; }).join("") + "</select></div>" +
          '<div><label>Data de nascimento</label><input data-f="date_of_birth" type="date" value="' + esc(rec.date_of_birth || "") + '"></div>' +
          '<div><label>Contacto</label><input data-f="phone" value="' + esc(rec.phone || "") + '"></div>' +
          '<div><label>NIF</label><input data-f="nif" value="' + esc(rec.nif || "") + '"></div>' +
          '<div><label>Formação</label><input data-f="formation" value="' + esc(rec.formation || "") + '"></div>' +
          '<div><label>Início de contrato</label><input data-f="contract_start" type="date" value="' + esc(rec.contract_start || "") + '"></div>' +
          '<div><label>Fim de contrato</label><input data-f="contract_end" type="date" value="' + esc(rec.contract_end || "") + '"></div>' +
          '<div class="full"><label>Morada</label><input data-f="address" value="' + esc(rec.address || "") + '"></div>' +
          '<div class="full"><label>Notas</label><textarea data-f="notes" rows="3">' + esc(rec.notes || "") + "</textarea></div></div>" +
          '<div class="st-foot"><button class="btn" type="button" data-dact="cancel-edit">Cancelar</button><button class="btn primary" type="button" data-dact="save">Guardar ficha</button></div></div>';
        dlg.innerHTML = html; dlg._ctx = { p: p, rec: rec, canSee: canSee };
        return;
      }

      html += '<div class="st-h">Dados profissionais</div>' +
        row("Email", esc(p.email)) + row("Departamento", esc(p.department)) + row("Categoria", esc(p.employee_category)) +
        row("Função de RH", esc(p.rh_role)) +
        row("Desempenho", (Number(p.news_month) || 0) + " no mês · " + (Number(p.news_week) || 0) + " na semana · " + (Number(p.total_published) || 0) + " no total · " + (Number(p.pending_approval) || 0) + " pendentes");

      if (canSee) {
        rec = rec || {};
        html += '<div class="st-h">Dados pessoais</div>' +
          row("Data de nascimento", fmtDay(rec.date_of_birth)) + row("Contacto", esc(rec.phone)) + row("Morada", esc(rec.address)) +
          row("NIF", esc(rec.nif)) + row("Formação", esc(rec.formation)) +
          row("Contrato", rec.contract_start ? fmtDay(rec.contract_start) + " até " + (rec.contract_end ? fmtDay(rec.contract_end) : "indeterminado") : "") +
          row("Notas", esc(rec.notes));
      } else {
        html += '<div class="st-lock"><b>Dados pessoais reservados.</b> NIF, morada, contacto, data de nascimento, formação e contrato só são visíveis ao próprio, ao RH e à direção.</div>';
      }

      if (canEditThis || canAccess || canStatus || canProfile) {
        html += '<div class="st-admin">';
        if (canEditThis) html += '<div><button class="btn" type="button" data-dact="edit">Editar ficha</button></div>';
        if (canAccess) {
          var opts = ASSIGNABLE.filter(function (c) { return levelOf(c) < P.level; });
          html += '<div class="st-inline"><b style="font-size:13px">Nível de acesso</b><select id="stAccess">' + opts.map(function (c) {
            return '<option value="' + c + '"' + (c === p.access_code ? " selected" : "") + ">" + c + " · " + esc(LABELS[c]) + "</option>";
          }).join("") + '</select><button class="btn sm primary" type="button" data-dact="access">Aplicar</button></div>';
        }
        if (canStatus) html += '<div><button class="btn danger" type="button" data-dact="status" data-v="' + (p.status === "ativo" ? "inativo" : "ativo") + '">' + (p.status === "ativo" ? "Desativar conta" : "Reativar conta") + "</button></div>";
        if (canProfile) html += '<div class="st-inline"><b style="font-size:13px">Perfil pendente</b><button class="btn sm primary" type="button" data-dact="prof-ok">Aprovar</button><button class="btn sm danger" type="button" data-dact="prof-no">Rejeitar</button></div>';
        html += "</div>";
      }
      html += '<div class="st-foot"><button class="btn" type="button" data-dact="close">Fechar</button></div></div>';
      dlg.innerHTML = html; dlg._ctx = { p: p, rec: rec, canSee: canSee };
    }

    function collect(box) {
      var o = {};
      box.querySelectorAll("[data-f]").forEach(function (el) { o[el.getAttribute("data-f")] = el.value.trim(); });
      return o;
    }
    async function rpc(name, args, okMsg, after) {
      var r = await sb.rpc(name, args);
      if (r.error) { toast("Erro: " + r.error.message); return false; }
      toast(okMsg); await refresh(); if (after) after(); return true;
    }
    async function onDialogAct(b) {
      var a = b.getAttribute("data-dact"), dlg = getDialog(), c = dlg._ctx || {}, p = c.p;
      if (a === "close") { dlg.close(); return; }
      if (a === "edit") { renderFicha(p, c.rec, c.canSee, true); return; }
      if (a === "cancel-edit") { renderFicha(p, c.rec, c.canSee, false); return; }
      if (a === "save") {
        var obj = collect(dlg.querySelector("#stEdit"));
        b.disabled = true;
        var ok = await rpc("staff_update", { target: p.id, p: obj }, "Ficha guardada.", function () { dlg.close(); });
        if (!ok) b.disabled = false;
        return;
      }
      if (a === "access") {
        await rpc("set_access", { target: p.id, new_code: dlg.querySelector("#stAccess").value }, "Nível de acesso atualizado.", function () { dlg.close(); });
        return;
      }
      if (a === "status") { await rpc("set_status", { target: p.id, new_status: b.getAttribute("data-v") }, "Estado da conta atualizado.", function () { dlg.close(); }); return; }
      if (a === "prof-ok" || a === "prof-no") {
        await rpc("approve_profile", { target: p.id, accept: a === "prof-ok" }, a === "prof-ok" ? "Perfil aprovado." : "Perfil rejeitado.", function () { dlg.close(); });
      }
    }

    /* ---------------- ações da página ---------------- */
    root.addEventListener("click", async function (e) {
      var b = e.target.closest("[data-act]");
      if (!b) return;
      var a = b.getAttribute("data-act"), id = b.getAttribute("data-id");
      if (a === "ficha") { openFicha(id); return; }
      if (a === "inv-ok" || a === "inv-no") {
        await rpc("approve_invite", { inv: id, accept: a === "inv-ok" }, a === "inv-ok" ? "Convite aprovado." : "Convite rejeitado.");
        return;
      }
      if (a === "invite") {
        var o = collect(root.querySelector("#stInv"));
        if (!o.full_name || !o.email) { toast("Nome e email são obrigatórios."); return; }
        b.disabled = true;
        var r = await sb.rpc("invite_staff", { p: o });
        b.disabled = false;
        if (r.error) { toast("Erro: " + r.error.message); return; }
        toast(P.approveInvites ? "Convite criado e aprovado. Peça à pessoa para criar conta com este email." : "Convite enviado para aprovação do proprietário.");
        await refresh();
      }
    });

    refresh();
    return { refresh: refresh };
  }

  window.PAStaff = { LEVELS: LEVELS, LABELS: LABELS, levelOf: levelOf, perms: perms, loadMe: loadMe, mount: mount, esc: esc };
})();
