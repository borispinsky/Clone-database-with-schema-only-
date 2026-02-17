DO $$
DECLARE
    v_min   bigint;
    v_max   bigint;
    v_lo    bigint;
    v_hi    bigint;
    v_batch constant bigint := 10000;
    v_rows  bigint;
BEGIN
    SELECT min(rn), max(rn)
      INTO v_min, v_max
      FROM temp_external_transaction_history_nilus_o;

    RAISE NOTICE 'rn range: % .. %', v_min, v_max;

    v_lo := v_min;

    WHILE v_lo <= v_max LOOP
        v_hi := v_lo + v_batch - 1;

        UPDATE external_transaction_history
        SET    nilus_id = et.nilus_id
        FROM   external_transactions et
        WHERE  external_transaction_history.transaction_id = et.id
          AND  EXISTS (
                SELECT 1
                FROM   temp_external_transaction_history_nilus_o t
                WHERE  t.transaction_id = et.id
                  AND  t.rn BETWEEN v_lo AND v_hi
               )
          AND  external_transaction_history.nilus_id = 0;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        RAISE NOTICE 'rn % .. %  ->  % rows updated', v_lo, v_hi, v_rows;

        COMMIT;

        PERFORM pg_sleep(1);

        v_lo := v_lo + v_batch;
    END LOOP;
END;
$$;
