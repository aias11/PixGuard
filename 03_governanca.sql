-- =====================================================================
-- PixGuard - 03_governanca.sql : views de acesso minimo + papeis (LGPD)
-- =====================================================================
USE pixguard;

-- View analitica: sem hashes de CPF, chave ou dispositivo.
-- E o que o time de analise de dados enxerga.
CREATE OR REPLACE VIEW vw_transacao_analitica AS
SELECT t.id              AS transacao_id,
       t.data_hora,
       t.valor,
       t.canal,
       t.status,
       t.score_risco,
       uo.faixa_etaria   AS faixa_etaria_pagador,
       uo.uf             AS uf_pagador,
       DATEDIFF(t.data_hora, cd.data_abertura) AS idade_conta_destino_dias,
       (SELECT COUNT(*) FROM alerta a WHERE a.transacao_id = t.id) AS qtd_alertas,
       d.tipo_golpe,
       d.status          AS status_denuncia
FROM transacao t
JOIN conta   co ON co.id = t.conta_origem_id
JOIN usuario uo ON uo.id = co.usuario_id
JOIN conta   cd ON cd.id = t.conta_destino_id
LEFT JOIN denuncia d ON d.transacao_id = t.id;

-- View de reputacao de chave: o que o app consulta antes de cada Pix.
CREATE OR REPLACE VIEW vw_reputacao_chave AS
SELECT c.id AS chave_id,
       c.valor_hash,
       c.valor_mascarado,
       DATEDIFF(CURRENT_DATE, ct.data_abertura) AS idade_conta_dias,
       COUNT(CASE WHEN d.status = 'CONFIRMADA' THEN 1 END) AS denuncias_confirmadas,
       COUNT(CASE WHEN d.status = 'EM_ANALISE' THEN 1 END) AS denuncias_em_analise
FROM chave_pix c
JOIN conta ct ON ct.id = c.conta_id
LEFT JOIN denuncia d ON d.chave_denunciada_id = c.id
GROUP BY c.id, c.valor_hash, c.valor_mascarado, ct.data_abertura;

-- Papeis com privilegio minimo
DROP ROLE IF EXISTS pixguard_analista, pixguard_motor_risco, pixguard_suporte;
CREATE ROLE pixguard_analista, pixguard_motor_risco, pixguard_suporte;

-- Analista: so le dados pseudonimizados pela view
GRANT SELECT ON pixguard.vw_transacao_analitica TO pixguard_analista;

-- Motor de risco (a API): consulta reputacao e grava transacoes/alertas
GRANT SELECT ON pixguard.vw_reputacao_chave TO pixguard_motor_risco;
GRANT SELECT, INSERT ON pixguard.transacao  TO pixguard_motor_risco;
GRANT SELECT, INSERT ON pixguard.alerta     TO pixguard_motor_risco;
GRANT SELECT ON pixguard.regra_risco        TO pixguard_motor_risco;

-- Suporte: registra e acompanha denuncias, sem ver transacoes de terceiros
GRANT SELECT, INSERT, UPDATE ON pixguard.denuncia TO pixguard_suporte;

SELECT 'views e papeis criados' AS status;
