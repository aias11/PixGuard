-- =====================================================================
-- PixGuard - 02_dados.sql : carga de amostra 100% FICTICIA
-- Gera dados de forma deterministica (sem RAND) para que o resultado
-- das consultas seja sempre o mesmo em qualquer computador.
--   * 50 clientes comuns  (usuarios 1-50)  -> ~3.000 Pix legitimos
--   * 8 contas "laranja"  (usuarios 51-58) -> recebem os golpes
--   * 2 contas concentradoras (59-60)      -> recebem das laranjas
--   * PixGuard entra em operacao em 09/11/2026 (alertas a partir dai)
-- =====================================================================
USE pixguard;
SET SESSION cte_max_recursion_depth = 10000;

-- Tabela auxiliar de numeros 1..3000 (apagada no fim)
DROP TEMPORARY TABLE IF EXISTS numeros;
CREATE TEMPORARY TABLE numeros (n INT UNSIGNED PRIMARY KEY);
INSERT INTO numeros (n)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 3000)
SELECT n FROM seq;

-- ---------------------------------------------------------------------
-- Instituicoes (nomes e ISPB inventados)
-- ---------------------------------------------------------------------
INSERT INTO instituicao (codigo_ispb, nome) VALUES
 ('10000001', 'Banco Aurora'),
 ('10000002', 'Banco Horizonte'),
 ('10000003', 'Fintech Vela'),
 ('10000004', 'Cooperativa Raiz'),
 ('10000005', 'Banco Atlantico'),
 ('10000006', 'PagFacil IP');

-- ---------------------------------------------------------------------
-- Regras do motor de risco
-- ---------------------------------------------------------------------
INSERT INTO regra_risco (codigo, descricao, peso) VALUES
 ('R01', 'Chave de destino com denuncia confirmada', 40),
 ('R02', 'Conta de destino aberta ha menos de 30 dias', 25),
 ('R03', 'Valor acima de 3x a media do pagador', 20),
 ('R04', 'Dispositivo usado por varias contas', 30),
 ('R05', 'Horario atipico (22h as 6h)', 10);

-- ---------------------------------------------------------------------
-- Usuarios (CPF so como hash; apelido no lugar do nome)
-- ---------------------------------------------------------------------
INSERT INTO usuario (id, cpf_hash, apelido, faixa_etaria, uf, data_cadastro, status)
SELECT n,
       SHA2(CONCAT('cpf-ficticio-', n), 256),
       CONCAT('Cliente ', LPAD(n, 3, '0')),
       ELT(n % 4 + 1, '18-29', '30-44', '45-59', '60+'),
       ELT(n % 5 + 1, 'SP', 'RJ', 'MG', 'BA', 'PR'),
       IF(n <= 50, DATE('2022-01-10') + INTERVAL (n * 17) DAY,
                   DATE('2026-10-14') + INTERVAL (n - 50) DAY),
       'ATIVO'
FROM numeros WHERE n <= 60;

-- ---------------------------------------------------------------------
-- Contas (1 por usuario; contas 51-60 abertas em outubro/2026)
-- ---------------------------------------------------------------------
INSERT INTO conta (id, usuario_id, instituicao_id, agencia, numero, tipo, data_abertura)
SELECT n, n,
       n % 6 + 1,
       LPAD(n % 9 + 1, 4, '0'),
       CONCAT(LPAD(n * 7919 % 1000000, 6, '0'), '-', n % 10),
       IF(n <= 50, ELT(n % 3 + 1, 'CORRENTE', 'POUPANCA', 'PAGAMENTO'), 'PAGAMENTO'),
       IF(n <= 50, DATE('2022-01-10') + INTERVAL (n * 17 + 3) DAY,
                   DATE('2026-10-15') + INTERVAL (n - 50) DAY)
FROM numeros WHERE n <= 60;

-- ---------------------------------------------------------------------
-- Chaves Pix (1 por conta; laranjas usam chave aleatoria)
-- ---------------------------------------------------------------------
INSERT INTO chave_pix (id, conta_id, tipo, valor_hash, valor_mascarado, criada_em, ativa)
SELECT c.id, c.id,
       IF(c.id > 50, 'ALEATORIA', ELT(c.id % 4 + 1, 'CPF', 'EMAIL', 'TELEFONE', 'ALEATORIA')),
       SHA2(CONCAT('chave-ficticia-', c.id), 256),
       CONCAT('***', LPAD(c.id, 3, '0'), '***'),
       TIMESTAMP(c.data_abertura) + INTERVAL 1 DAY,
       TRUE
FROM conta c;

-- ---------------------------------------------------------------------
-- Dispositivos: 1-50 = um por cliente; 51-52 = 2 celulares que operam
-- todas as contas laranja (sinal classico de quadrilha)
-- ---------------------------------------------------------------------
INSERT INTO dispositivo (id, fingerprint_hash, sistema, primeiro_uso)
SELECT n,
       SHA2(CONCAT('device-ficticio-', n), 256),
       ELT(n % 3 + 1, 'ANDROID', 'IOS', 'WEB'),
       IF(n <= 50, TIMESTAMP('2022-01-15') + INTERVAL (n * 17) DAY,
                   TIMESTAMP('2026-10-16'))
FROM numeros WHERE n <= 52;

-- ---------------------------------------------------------------------
-- 3.000 Pix legitimos entre clientes comuns (01/10 a 23/11/2026)
-- cada cliente paga sempre os mesmos 3 recebedores (padrao realista)
-- ---------------------------------------------------------------------
INSERT INTO transacao (end_to_end_id, conta_origem_id, chave_destino_id, conta_destino_id,
                       dispositivo_id, valor, data_hora, canal, status, score_risco)
SELECT CONCAT('E', LPAD(n, 31, '0')),
       o, d, d, o,
       ROUND(15 + (n * 37 % 485) + (n % 100) / 100, 2),
       TIMESTAMP('2026-10-01 07:00:00') + INTERVAL (n * 1031 % (54 * 24 * 60)) MINUTE,
       ELT(n % 4 + 1, 'APP', 'APP', 'QR_CODE', 'INTERNET_BANKING'),
       'CONCLUIDA',
       n * 17 % 30
FROM (SELECT n,
             (n * 7) % 50 + 1                              AS o,
             (((n * 7) % 50 + 1) + (n % 3) * 7 + 2) % 50 + 1 AS d
      FROM numeros) x;

-- ---------------------------------------------------------------------
-- 150 Pix de golpe: vitima -> conta laranja (01/11 a 23/11/2026)
-- Apos 09/11 o PixGuard alerta; 1 em cada 3 vitimas desiste (CANCELADA)
-- ---------------------------------------------------------------------
INSERT INTO transacao (end_to_end_id, conta_origem_id, chave_destino_id, conta_destino_id,
                       dispositivo_id, valor, data_hora, canal, status, score_risco)
SELECT CONCAT('F', LPAD(n, 31, '0')),
       v, m, m, v,
       ROUND(250 + (n * 97 % 2750) + (n % 7) * 0.5, 2),
       dh,
       IF(n % 5 = 0, 'QR_CODE', 'APP'),
       IF(dh >= '2026-11-09' AND n % 3 = 0, 'CANCELADA', 'CONCLUIDA'),
       60 + n * 7 % 36
FROM (SELECT n,
             (n * 11) % 50 + 1 AS v,
             51 + (n % 8)      AS m,
             TIMESTAMP('2026-11-01') + INTERVAL ((n - 1) * 23 DIV 150) DAY
                 + INTERVAL IF(n % 4 = 0, 10 + n % 6, 18 + n % 5) HOUR
                 + INTERVAL (n * 7 % 60) MINUTE AS dh
      FROM numeros WHERE n <= 150) x;

-- ---------------------------------------------------------------------
-- 48 Pix de "lavagem": laranja -> concentradora, feitos de madrugada
-- a partir dos 2 dispositivos compartilhados
-- ---------------------------------------------------------------------
INSERT INTO transacao (end_to_end_id, conta_origem_id, chave_destino_id, conta_destino_id,
                       dispositivo_id, valor, data_hora, canal, status, score_risco)
SELECT CONCAT('L', LPAD(n, 31, '0')),
       51 + (n % 8),
       59 + (n DIV 8) % 2,
       59 + (n DIV 8) % 2,
       51 + (n DIV 3) % 2,
       ROUND(800 + (n * 131 % 2200), 2),
       TIMESTAMP('2026-11-01 23:00:00') + INTERVAL ((n - 1) * 22 DIV 48) DAY
           + INTERVAL (n * 13 % 50) MINUTE,
       'INTERNET_BANKING',
       'CONCLUIDA',
       40 + n % 30
FROM numeros WHERE n <= 48;

-- 4 transferencias entre as duas concentradoras (3o salto da rede)
INSERT INTO transacao (end_to_end_id, conta_origem_id, chave_destino_id, conta_destino_id,
                       dispositivo_id, valor, data_hora, canal, status, score_risco)
VALUES
 (CONCAT('L', LPAD(901, 31, '0')), 59, 60, 60, 51, 9800.00, '2026-11-06 02:10:00', 'INTERNET_BANKING', 'CONCLUIDA', 55),
 (CONCAT('L', LPAD(902, 31, '0')), 59, 60, 60, 51, 12450.00, '2026-11-12 02:40:00', 'INTERNET_BANKING', 'CONCLUIDA', 61),
 (CONCAT('L', LPAD(903, 31, '0')), 59, 60, 60, 52, 8700.00, '2026-11-18 03:05:00', 'INTERNET_BANKING', 'CONCLUIDA', 58),
 (CONCAT('L', LPAD(904, 31, '0')), 59, 60, 60, 52, 15100.00, '2026-11-22 01:55:00', 'INTERNET_BANKING', 'CONCLUIDA', 66);

-- ---------------------------------------------------------------------
-- Denuncias: vitimas que concluiram o Pix de golpe (4 em cada 5 denunciam)
-- ---------------------------------------------------------------------
INSERT INTO denuncia (transacao_id, denunciante_id, chave_denunciada_id, tipo_golpe,
                      dominio_link, data_denuncia, status)
SELECT t.id,
       t.conta_origem_id,              -- conta = usuario no prototipo
       t.chave_destino_id,
       ELT(x.n % 4 + 1, 'FALSO_PARENTE', 'FALSA_CENTRAL', 'LINK_FALSO', 'FALSA_VENDA'),
       IF(x.n % 4 = 2,
          ELT(x.n % 3 + 1, 'pix-premiado.example', 'atualiza-seguranca.example', 'taxa-entrega.example'),
          NULL),
       t.data_hora + INTERVAL (2 + x.n % 40) HOUR,
       IF(x.n % 9 = 0, 'EM_ANALISE', 'CONFIRMADA')
FROM transacao t
JOIN (SELECT n FROM numeros WHERE n <= 150) x
  ON t.end_to_end_id = CONCAT('F', LPAD(x.n, 31, '0'))
WHERE t.status = 'CONCLUIDA' AND x.n % 5 <> 0;

-- 3 denuncias improcedentes (desacordo comercial, nao era golpe)
INSERT INTO denuncia (transacao_id, denunciante_id, chave_denunciada_id, tipo_golpe,
                      dominio_link, data_denuncia, status)
SELECT t.id, t.conta_origem_id, t.chave_destino_id, 'FALSA_VENDA', NULL,
       t.data_hora + INTERVAL 1 DAY, 'IMPROCEDENTE'
FROM transacao t
WHERE t.end_to_end_id IN (CONCAT('E', LPAD(100, 31, '0')),
                          CONCAT('E', LPAD(1500, 31, '0')),
                          CONCAT('E', LPAD(2700, 31, '0')));

-- ---------------------------------------------------------------------
-- Alertas (somente a partir do lancamento, 09/11/2026)
-- ---------------------------------------------------------------------
-- R02: toda transferencia para conta com menos de 30 dias
INSERT INTO alerta (transacao_id, regra_id, score, usuario_prosseguiu, criado_em)
SELECT t.id, (SELECT id FROM regra_risco WHERE codigo = 'R02'), t.score_risco,
       t.status = 'CONCLUIDA', t.data_hora
FROM transacao t JOIN conta c ON c.id = t.conta_destino_id
WHERE t.data_hora >= '2026-11-09'
  AND DATEDIFF(t.data_hora, c.data_abertura) < 30;

-- R01: chave que ja tinha denuncia confirmada antes da transacao
INSERT INTO alerta (transacao_id, regra_id, score, usuario_prosseguiu, criado_em)
SELECT t.id, (SELECT id FROM regra_risco WHERE codigo = 'R01'), LEAST(t.score_risco + 5, 100),
       t.status = 'CONCLUIDA', t.data_hora
FROM transacao t
WHERE t.data_hora >= '2026-11-09'
  AND EXISTS (SELECT 1 FROM denuncia d
              WHERE d.chave_denunciada_id = t.chave_destino_id
                AND d.status = 'CONFIRMADA'
                AND d.data_denuncia < t.data_hora);

-- R04: Pix feito de dispositivo usado por 3+ contas diferentes
INSERT INTO alerta (transacao_id, regra_id, score, usuario_prosseguiu, criado_em)
SELECT t.id, (SELECT id FROM regra_risco WHERE codigo = 'R04'), t.score_risco,
       t.status = 'CONCLUIDA', t.data_hora
FROM transacao t
WHERE t.data_hora >= '2026-11-09'
  AND t.dispositivo_id IN (SELECT dispositivo_id FROM transacao
                           GROUP BY dispositivo_id
                           HAVING COUNT(DISTINCT conta_origem_id) >= 3);

-- R03: falsos positivos - Pix legitimos de valor alto (cliente seguiu em frente)
INSERT INTO alerta (transacao_id, regra_id, score, usuario_prosseguiu, criado_em)
SELECT t.id, (SELECT id FROM regra_risco WHERE codigo = 'R03'), 55, TRUE, t.data_hora
FROM transacao t
WHERE t.data_hora >= '2026-11-09'
  AND t.end_to_end_id LIKE 'E%'
  AND t.valor >= 480;

-- Contas concentradoras bloqueadas apos investigacao
UPDATE usuario SET status = 'BLOQUEADO' WHERE id IN (59, 60);

DROP TEMPORARY TABLE numeros;

-- Resumo da carga
SELECT 'instituicao' AS tabela, COUNT(*) AS linhas FROM instituicao
UNION ALL SELECT 'usuario',     COUNT(*) FROM usuario
UNION ALL SELECT 'conta',       COUNT(*) FROM conta
UNION ALL SELECT 'chave_pix',   COUNT(*) FROM chave_pix
UNION ALL SELECT 'dispositivo', COUNT(*) FROM dispositivo
UNION ALL SELECT 'transacao',   COUNT(*) FROM transacao
UNION ALL SELECT 'denuncia',    COUNT(*) FROM denuncia
UNION ALL SELECT 'regra_risco', COUNT(*) FROM regra_risco
UNION ALL SELECT 'alerta',      COUNT(*) FROM alerta;
