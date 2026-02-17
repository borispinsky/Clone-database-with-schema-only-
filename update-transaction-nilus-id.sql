UPDATE external_transaction_history eth
SET    nilus_id = et.nilus_id
FROM   external_transactions et
JOIN   temp_external_transaction_history_nilus_o t ON t.transaction_id = et.id
WHERE  eth.transaction_id = et.id
  AND  eth.nilus_id = 0;
