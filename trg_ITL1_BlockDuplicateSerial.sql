USE [LiloMallTest ]

GO

/****** Object:  Trigger [dbo].[trg_ITL1_BlockDuplicateSerial]    Script Date: 31.10.2025 13:48:03 ******/

SET ANSI_NULLS ON

GO

SET QUOTED_IDENTIFIER ON

GO



ALTER TRIGGER [dbo].[trg_ITL1_BlockDuplicateSerial]

ON [dbo].[ITL1]

AFTER INSERT

AS

BEGIN

    SET NOCOUNT ON;



    -------------------------------------------------------------------------

    -- 1) Current posting movements (OITL) for rows inserted to ITL1

    -------------------------------------------------------------------------

    DECLARE @CurrentLogs TABLE

    (

        LogEntry  INT PRIMARY KEY,

        DocType   INT NOT NULL,

        StockQty  NUMERIC(19,6) NOT NULL

    );



    INSERT INTO @CurrentLogs (LogEntry, DocType, StockQty)

    SELECT DISTINCT o.LogEntry, o.DocType, o.StockQty

    FROM dbo.OITL o

    JOIN inserted i ON i.LogEntry = o.LogEntry;



    -------------------------------------------------------------------------

    -- Helper predicates (inline, no temp tables):

    --  PosCancelTypes = (13,15,19,67)  → cancellation if StockQty > 0

    --  NegCancelTypes = NOT IN (13,15,19,67) → cancellation if StockQty < 0

    -------------------------------------------------------------------------

    -- Current cancellations: serials in the current posting that are cancellations

    DECLARE @CurrentCancelDist TABLE (DistNumber NVARCHAR(100) NOT NULL PRIMARY KEY);



    INSERT INTO @CurrentCancelDist (DistNumber)

    SELECT DISTINCT LTRIM(RTRIM(s.DistNumber))

    FROM inserted i

    JOIN @CurrentLogs cl ON cl.LogEntry = i.LogEntry

    JOIN dbo.OSRN s

      ON s.ItemCode  = i.ItemCode

     AND s.SysNumber = i.SysNumber

    WHERE s.DistNumber IS NOT NULL

      AND LTRIM(RTRIM(s.DistNumber)) <> N''

      AND (

            -- PosCancelTypes

            (cl.DocType IN (13,15,19,67) AND cl.StockQty > 0)

            -- NegCancelTypes (all others)

         OR (cl.DocType NOT IN (13,15,19,67) AND cl.StockQty < 0)

          );



    -------------------------------------------------------------------------

    -- 2) Candidate DistNumbers to validate (global uniqueness):

    --    - current inbound rows (StockQty > 0)

    --    - NOT part of current cancellation rows

    -------------------------------------------------------------------------

    DECLARE @DistSet TABLE (DistNumber NVARCHAR(100) NOT NULL PRIMARY KEY);



    INSERT INTO @DistSet (DistNumber)

    SELECT DISTINCT LTRIM(RTRIM(s.DistNumber))

    FROM inserted i

    JOIN @CurrentLogs cl ON cl.LogEntry = i.LogEntry

    JOIN dbo.OSRN s WITH (UPDLOCK, HOLDLOCK)

      ON s.ItemCode  = i.ItemCode

     AND s.SysNumber = i.SysNumber

    WHERE cl.StockQty > 0

      AND s.DistNumber IS NOT NULL

      AND LTRIM(RTRIM(s.DistNumber)) <> N''

      AND NOT EXISTS (SELECT 1 FROM @CurrentCancelDist c WHERE c.DistNumber = LTRIM(RTRIM(s.DistNumber)));



    -- Nothing to validate → exit

    IF NOT EXISTS (SELECT 1 FROM @DistSet) RETURN;



    -------------------------------------------------------------------------

    -- 3) Guard: duplicate serials within the SAME posting → BLOCK

    -------------------------------------------------------------------------

    IF EXISTS

    (

        SELECT 1

        FROM

        (

            SELECT LTRIM(RTRIM(s.DistNumber)) AS DistNumber, COUNT(*) AS Cnt

            FROM inserted i

            JOIN @CurrentLogs cl ON cl.LogEntry = i.LogEntry

            JOIN dbo.OSRN s ON s.ItemCode = i.ItemCode AND s.SysNumber = i.SysNumber

            WHERE cl.StockQty > 0

            GROUP BY LTRIM(RTRIM(s.DistNumber))

        ) t

        WHERE t.Cnt > 1

    )

    BEGIN

        DECLARE @msgDup NVARCHAR(2048);

        SET @msgDup = N'სერიული ნომერი დუბლირდება ამავე დოკუმენტში.';

        THROW 50001, @msgDup, 1;

    END



    -------------------------------------------------------------------------

    -- 4) Latest PRIOR movement per DistNumber (exclude current posting)

    -------------------------------------------------------------------------

    DECLARE @LatestPrior TABLE

    (

        DistNumber NVARCHAR(100) NOT NULL PRIMARY KEY,

        LogEntry   INT           NULL,

        DocType    INT           NULL,

        StockQty   NUMERIC(19,6) NULL

    );



    INSERT INTO @LatestPrior (DistNumber, LogEntry, DocType, StockQty)

    SELECT ds.DistNumber,

           x.LogEntry, x.DocType, x.StockQty

    FROM @DistSet ds

    OUTER APPLY

    (

        SELECT TOP (1)

               o.LogEntry,

               o.DocType,

               o.StockQty

        FROM dbo.OITL o

        JOIN dbo.ITL1 i1

          ON i1.LogEntry = o.LogEntry

        JOIN dbo.OSRN s2

          ON s2.ItemCode  = i1.ItemCode

         AND s2.SysNumber = i1.SysNumber

        WHERE LTRIM(RTRIM(s2.DistNumber)) = ds.DistNumber

          AND NOT EXISTS (SELECT 1 FROM @CurrentLogs cl WHERE cl.LogEntry = o.LogEntry) -- exclude current posting

        ORDER BY o.LogEntry DESC

    ) x;



    -------------------------------------------------------------------------

    -- 5) Apply rules using the sign-based cancellation heuristic

    --    A) Prior is cancellation AND DocType IN (13,15,19,67) → BLOCK

    --       (i.e., (DocType IN (13,15,19,67) AND StockQty > 0) OR

    --              (DocType NOT IN (13,15,19,67) AND StockQty < 0))

    --       AND additionally DocType IN (13,15,19,67).

    --    B) Prior is NOT cancellation → BLOCK, except (DocType = 10000071 AND StockQty < 0).

    -------------------------------------------------------------------------

    DECLARE @BadDist NVARCHAR(100);



    SELECT TOP (1) @BadDist = lp.DistNumber

    FROM @LatestPrior lp

    WHERE lp.LogEntry IS NOT NULL

      AND

      (

          -- A) Prior is cancellation AND DocType in (13,15,19,67,60) → BLOCK

          (

              (

                   (lp.DocType IN (13,15,19,67) AND lp.StockQty > 0)

                OR (lp.DocType NOT IN (13,15,19,67) AND lp.StockQty < 0)

              )

              AND lp.DocType IN (13,15,19,67,60)   -- << here

          )

          OR

          -- B) Prior is NOT cancellation → BLOCK, except explicit exception

          (

              NOT (

                   (lp.DocType IN (13,15,19,67) AND lp.StockQty > 0)

                OR (lp.DocType NOT IN (13,15,19,67) AND lp.StockQty < 0)

              )

              AND NOT (lp.DocType = 10000071 AND lp.StockQty < 0)

          )

      )

ORDER BY lp.DistNumber;



    IF @BadDist IS NOT NULL

    BEGIN

        DECLARE @msg NVARCHAR(2048);

        SET @msg = N'აღნიშნული სერიული ნომერი უკვე გამოყენებულია. DistNumber: ' + @BadDist;

        THROW 50001, @msg, 1;

    END

END

