-- =====================================================================
-- PixGuard - 05_qualidade.sql : verificacoes de qualidade dos dados
-- Parte A: auditorias (devem retornar 0 problemas)
-- Parte B: testes de rejeicao (cada dado invalido deve ser rejeitado)
-- =====================================================================
USE pixguard;

-- Parte A ---------------------------------------------------------------
SELECT 'unicidade: end_to_end_id duplicado' AS verificacao,
       COUNT(*) - COUNT(DISTINCT end_to_end_id) AS problemas FROM transacao
UNION ALL
SELECT 'unicidade: CPF (hash) duplicado',
       COUNT(*) - COUNT(DISTINCT cpf_hash) FROM usuario
UNION ALL
SELECT 'consistencia: chave da denuncia diferente da chave do Pix',
       COUNT(*) FROM denuncia d JOIN transacao t ON t.id = d.transacao_id
       WHERE d.chave_denunciada_id <> t.chave_destino_id
UNION ALL
SELECT 'consistencia: chave Pix nao pertence a conta de destino',
       COUNT(*) FROM transacao t JOIN chave_pix c ON c.id = t.chave_destino_id
       WHERE c.conta_id <> t.conta_destino_id
UNION ALL
SELECT 'validade: denuncia registrada antes do Pix',
       COUNT(*) FROM denuncia d JOIN transacao t ON t.id = d.transacao_id
       WHERE d.data_denuncia < t.data_hora
UNION ALL
SELECT 'atualidade: transacao com data futura',
       COUNT(*) FROM transacao WHERE data_hora > NOW()
UNION ALL
SELECT 'completude: golpe LINK_FALSO sem dominio',
       COUNT(*) FROM denuncia WHERE tipo_golpe = 'LINK_FALSO' AND dominio_link IS NULL
UNION ALL
SELECT 'validade: alerta em Pix cancelado marcado como prosseguiu',
       COUNT(*) FROM alerta a JOIN transacao t ON t.id = a.transacao_id
       WHERE t.status = 'CANCELADA' AND a.usuario_prosseguiu = TRUE;

-- Parte B ---------------------------------------------------------------
-- Cada teste tenta gravar um dado INVALIDO. O procedimento captura o erro
-- do MySQL (em vez de parar o script) e registra se o banco rejeitou.
-- Resultado esperado: todas as linhas com "OK: rejeitado".
DROP PROCEDURE IF EXISTS pr_testar_rejeicao;
DROP TEMPORARY TABLE IF EXISTS teste_rejeicao;
CREATE TEMPORARY TABLE teste_rejeicao (
    teste           VARCHAR(60),
    resultado       VARCHAR(40),
    mensagem_mysql  VARCHAR(255)
);

DELIMITER //
CREATE PROCEDURE pr_testar_rejeicao(IN p_teste VARCHAR(60), IN p_sql TEXT)
BEGIN
    DECLARE v_msg TEXT DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;

    START TRANSACTION;
    SET @pg_sql = p_sql;
    PREPARE st FROM @pg_sql;
    EXECUTE st;
    DEALLOCATE PREPARE st;
    ROLLBACK;   -- garante que nada fica gravado, mesmo se o teste falhar

    INSERT INTO teste_rejeicao (teste, resultado, mensagem_mysql)
    VALUES (p_teste,
            IF(v_msg IS NULL, 'FALHOU: dado invalido entrou', 'OK: rejeitado'),
            COALESCE(LEFT(v_msg, 255), '-'));
END//
DELIMITER ;

CALL pr_testar_rejeicao('B1 Pix de valor negativo',
  'INSERT INTO transacao (end_to_end_id, conta_origem_id, chave_destino_id, conta_destino_id, dispositivo_id, valor, data_hora, canal, status)
   VALUES (''TESTE000000000000000000000000001'', 1, 2, 2, 1, -50.00, NOW(), ''APP'', ''CONCLUIDA'')');

CALL pr_testar_rejeicao('B2 Pix para a propria conta',
  'INSERT INTO transacao (end_to_end_id, conta_origem_id, chave_destino_id, conta_destino_id, dispositivo_id, valor, data_hora, canal, status)
   VALUES (''TESTE000000000000000000000000002'', 1, 1, 1, 1, 10.00, NOW(), ''APP'', ''CONCLUIDA'')');

CALL pr_testar_rejeicao('B3 Pix de conta inexistente',
  'INSERT INTO transacao (end_to_end_id, conta_origem_id, chave_destino_id, conta_destino_id, dispositivo_id, valor, data_hora, canal, status)
   VALUES (''TESTE000000000000000000000000003'', 999, 2, 2, 1, 10.00, NOW(), ''APP'', ''CONCLUIDA'')');

CALL pr_testar_rejeicao('B4 Denuncia duplicada',
  'INSERT INTO denuncia (transacao_id, denunciante_id, chave_denunciada_id, tipo_golpe, data_denuncia)
   SELECT transacao_id, denunciante_id, chave_denunciada_id, tipo_golpe, NOW() FROM denuncia ORDER BY id LIMIT 1');

CALL pr_testar_rejeicao('B5 Link falso sem dominio',
  'INSERT INTO denuncia (transacao_id, denunciante_id, chave_denunciada_id, tipo_golpe, data_denuncia)
   VALUES (1, 1, 2, ''LINK_FALSO'', NOW())');

CALL pr_testar_rejeicao('B6 UF em minusculas',
  'INSERT INTO usuario (cpf_hash, apelido, faixa_etaria, uf, data_cadastro)
   VALUES (SHA2(''cpf-teste'', 256), ''Teste'', ''30-44'', ''sp'', CURRENT_DATE)');

-- Resultado dos testes
SELECT * FROM teste_rejeicao;

-- Prova de que nada entrou no banco
SELECT (SELECT COUNT(*) FROM transacao WHERE end_to_end_id LIKE 'TESTE%')
     + (SELECT COUNT(*) FROM usuario   WHERE apelido = 'Teste') AS registros_de_teste_que_entraram;

DROP PROCEDURE pr_testar_rejeicao;
DROP TEMPORARY TABLE teste_rejeicao;
