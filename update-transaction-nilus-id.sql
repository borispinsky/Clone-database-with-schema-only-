DO $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT et.id AS transaction_id, et.nilus_id
        FROM   external_transactions et
        JOIN   temp_external_transaction_history_nilus_o t ON t.transaction_id = et.id
    LOOP
        UPDATE external_transaction_history
        SET    nilus_id = rec.nilus_id
        WHERE  transaction_id = rec.transaction_id
          AND  nilus_id = 0;
    END LOOP;
END $$;
