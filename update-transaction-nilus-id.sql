UPDATE external_transaction_history
SET    nilus_id = et.nilus_id
FROM   external_transactions et
WHERE  external_transaction_history.transaction_id = et.id
  AND EXISTS (
        SELECT 1
        FROM   temp_external_transaction_history_nilus_o t
        WHERE  t.transaction_id = et.id
          AND  t.rn BETWEEN 70000 AND 80000
      )
  AND external_transaction_history.nilus_id = 0;
