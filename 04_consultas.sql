-- =====================================================================
-- PixGuard - 04_consultas.sql : 8 consultas que respondem as perguntas
-- de negocio. Data de referencia do relatorio: 24/11/2026.
-- =====================================================================
USE pixguard;
SET @lancamento = '2026-11-09';
SET @referencia = '2026-11-24';

-- ---------------------------------------------------------------------
-- C1. Quais chaves Pix concentram mais golpes confirmados e quanto
--     dinheiro elas receberam das vitimas?
-- ---------------------------------------------------------------------
SELECT c.id                                   AS chave_id,
       c.valor_mascarado                      AS chave,
       ct.data_abertura                       AS conta_aberta_em,
       COUNT(*)                               AS golpes_confirmados,
       SUM(t.valor)                           AS prejuizo_vitimas_rs,
       DATEDIFF(MIN(d.data_denuncia), ct.data_abertura) AS dias_ate_1a_denuncia
FROM denuncia d
JOIN chave_pix c ON c.id = d.chave_denunciada_id
JOIN conta ct    ON ct.id = c.conta_id
JOIN transacao t ON t.id = d.transacao_id
WHERE d.status = 'CONFIRMADA'
GROUP BY c.id, c.valor_mascarado, ct.data_abertura
ORDER BY golpes_confirmados DESC, prejuizo_vitimas_rs DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- C2. Quais tipos de golpe sao mais comuns e quais causam mais prejuizo?
-- ---------------------------------------------------------------------
SELECT d.tipo_golpe,
       COUNT(*)                                         AS denuncias,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_denuncias,
       SUM(t.valor)                                     AS prejuizo_rs,
       ROUND(AVG(t.valor), 2)                           AS ticket_medio_rs
FROM denuncia d
JOIN transacao t ON t.id = d.transacao_id
WHERE d.status = 'CONFIRMADA'
GROUP BY d.tipo_golpe
ORDER BY prejuizo_rs DESC;

-- ---------------------------------------------------------------------
-- C3. Quais contas tem comportamento de "conta laranja"?
--     (conta com menos de 30 dias recebendo de 5+ pagadores diferentes
--      nos ultimos 14 dias)
-- ---------------------------------------------------------------------
SELECT t.conta_destino_id                            AS conta_id,
       ct.data_abertura,
       DATEDIFF(@referencia, ct.data_abertura)       AS idade_conta_dias,
       COUNT(DISTINCT t.conta_origem_id)             AS pagadores_distintos,
       COUNT(*)                                      AS pix_recebidos,
       SUM(t.valor)                                  AS total_recebido_rs
FROM transacao t
JOIN conta ct ON ct.id = t.conta_destino_id
WHERE t.status = 'CONCLUIDA'
  AND t.data_hora >= @referencia - INTERVAL 14 DAY
GROUP BY t.conta_destino_id, ct.data_abertura
HAVING pagadores_distintos >= 5
   AND MIN(DATEDIFF(t.data_hora, ct.data_abertura)) < 30
ORDER BY pagadores_distintos DESC;

-- ---------------------------------------------------------------------
-- C4. Para onde foi o dinheiro? Rede de contas a partir da chave mais
--     denunciada, seguindo ate 3 saltos (CTE recursiva).
-- ---------------------------------------------------------------------
WITH RECURSIVE
inicio AS (
    SELECT c.conta_id
    FROM denuncia d JOIN chave_pix c ON c.id = d.chave_denunciada_id
    WHERE d.status = 'CONFIRMADA'
    GROUP BY c.conta_id
    ORDER BY COUNT(*) DESC, c.conta_id
    LIMIT 1
),
rede (conta_id, salto, caminho) AS (
    SELECT conta_id, 0, CAST(conta_id AS CHAR(200)) FROM inicio
    UNION DISTINCT
    SELECT t.conta_destino_id, r.salto + 1, CONCAT(r.caminho, ' > ', t.conta_destino_id)
    FROM rede r
    JOIN transacao t ON t.conta_origem_id = r.conta_id AND t.status = 'CONCLUIDA'
    WHERE r.salto < 3
      AND FIND_IN_SET(t.conta_destino_id, REPLACE(r.caminho, ' > ', ',')) = 0
)
SELECT r.salto,
       r.caminho                         AS caminho_do_dinheiro,
       u.apelido                         AS titular_final,
       u.status                          AS status_titular,
       (SELECT SUM(t.valor) FROM transacao t
         WHERE t.conta_destino_id = r.conta_id AND t.status = 'CONCLUIDA') AS total_recebido_rs
FROM rede r
JOIN conta c   ON c.id = r.conta_id
JOIN usuario u ON u.id = c.usuario_id
ORDER BY r.salto, r.caminho;

-- ---------------------------------------------------------------------
-- C5. Existe um mesmo aparelho movimentando varias contas? (quadrilha)
-- ---------------------------------------------------------------------
SELECT t.dispositivo_id,
       dv.sistema,
       COUNT(DISTINCT t.conta_origem_id)                                   AS contas_operadas,
       GROUP_CONCAT(DISTINCT t.conta_origem_id ORDER BY t.conta_origem_id) AS lista_contas,
       COUNT(*)                                                            AS pix_enviados,
       SUM(t.valor)                                                        AS valor_movimentado_rs
FROM transacao t
JOIN dispositivo dv ON dv.id = t.dispositivo_id
GROUP BY t.dispositivo_id, dv.sistema
HAVING contas_operadas >= 3
ORDER BY contas_operadas DESC;

-- ---------------------------------------------------------------------
-- C6. KPI principal: o alerta do PixGuard faz a vitima desistir?
--     Quanto dinheiro foi protegido desde o lancamento?
-- ---------------------------------------------------------------------
WITH tx_alertada AS (
    SELECT t.id, t.valor, t.end_to_end_id,
           MAX(a.usuario_prosseguiu) AS prosseguiu,
           EXISTS (SELECT 1 FROM denuncia d
                   WHERE d.transacao_id = t.id AND d.status <> 'IMPROCEDENTE') AS virou_denuncia
    FROM transacao t
    JOIN alerta a ON a.transacao_id = t.id
    WHERE t.conta_origem_id <= 50          -- so Pix feitos por clientes comuns
    GROUP BY t.id, t.valor, t.end_to_end_id
)
SELECT COUNT(*)                                               AS pix_alertados,
       SUM(prosseguiu = 0)                                    AS desistencias,
       ROUND(100 * AVG(prosseguiu = 0), 1)                    AS taxa_desistencia_pct,
       SUM(CASE WHEN prosseguiu = 0 THEN valor ELSE 0 END)    AS valor_protegido_rs,
       SUM(prosseguiu = 1 AND virou_denuncia)                 AS golpes_mesmo_com_alerta,
       SUM(prosseguiu = 1 AND NOT virou_denuncia
           AND end_to_end_id LIKE 'E%')                       AS falsos_positivos
FROM tx_alertada;

-- ---------------------------------------------------------------------
-- C7. Quem sao as vitimas mais frequentes e em que horario o golpe
--     acontece? (direciona campanhas de prevencao)
-- ---------------------------------------------------------------------
SELECT u.faixa_etaria,
       SUM(HOUR(t.data_hora) BETWEEN 6 AND 11)  AS manha,
       SUM(HOUR(t.data_hora) BETWEEN 12 AND 17) AS tarde,
       SUM(HOUR(t.data_hora) >= 18 OR HOUR(t.data_hora) < 6) AS noite,
       COUNT(*)                                 AS total_golpes,
       SUM(t.valor)                             AS prejuizo_rs
FROM denuncia d
JOIN transacao t ON t.id = d.transacao_id
JOIN usuario u   ON u.id = d.denunciante_id
WHERE d.status = 'CONFIRMADA'
GROUP BY u.faixa_etaria
ORDER BY total_golpes DESC;

-- ---------------------------------------------------------------------
-- C8. Evolucao semanal: tentativas de golpe x golpes concretizados
--     antes e depois do lancamento do PixGuard (09/11/2026)
-- ---------------------------------------------------------------------
SELECT DATE(t.data_hora - INTERVAL WEEKDAY(t.data_hora) DAY) AS semana_inicio,
       IF(MIN(t.data_hora) >= @lancamento, 'com PixGuard', 'sem PixGuard') AS fase,
       COUNT(*)                               AS tentativas_golpe,
       SUM(t.status = 'CANCELADA')            AS evitados,
       SUM(t.status = 'CONCLUIDA')            AS concretizados,
       SUM(CASE WHEN t.status = 'CONCLUIDA' THEN t.valor ELSE 0 END) AS prejuizo_rs
FROM transacao t
WHERE t.end_to_end_id LIKE 'F%'
GROUP BY semana_inicio
ORDER BY semana_inicio;
