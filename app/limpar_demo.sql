-- PixGuard - apaga os Pix feitos pelo app durante a demonstracao
-- (end_to_end_id comecando com 'A'), com seus alertas e denuncias.
-- Os dados originais da carga (02_dados.sql) nao sao tocados.
USE pixguard;
DELETE d FROM denuncia d JOIN transacao t ON t.id = d.transacao_id WHERE t.end_to_end_id LIKE 'A%';
DELETE a FROM alerta a   JOIN transacao t ON t.id = a.transacao_id WHERE t.end_to_end_id LIKE 'A%';
DELETE FROM transacao WHERE end_to_end_id LIKE 'A%';
SELECT (SELECT COUNT(*) FROM transacao) AS transacoes,
       (SELECT COUNT(*) FROM denuncia)  AS denuncias,
       (SELECT COUNT(*) FROM alerta)    AS alertas;
