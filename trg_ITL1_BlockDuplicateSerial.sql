GO
/****** Object:  Trigger [dbo].[trg_ITL1_BlockDuplicateSerial]    Script Date: 10.10.2025 15:33:54 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE TRIGGER [dbo].[trg_ITL1_BlockDuplicateSerial]
ON [dbo].[ITL1]
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- 1) Current posting's OITL rows for the inserted ITL1 (to know direction)
    DECLARE @CurrentLogs TABLE (
        LogEntry INT PRIMARY KEY,
        DocType  INT NULL,
        StockQty NUMERIC(19,6) NULL
    );

    INSERT INTO @CurrentLogs (LogEntry, DocType, StockQty)
    SELECT DISTINCT o.LogEntry, o.DocType, o.StockQty
    FROM dbo.OITL o
    JOIN inserted i ON i.LogEntry = o.LogEntry;

    -- 2) DistNumbers from ONLY the inbound (StockQty > 0) current rows
    DECLARE @DistSet TABLE (DistNumber NVARCHAR(100) NOT NULL PRIMARY KEY);

    INSERT INTO @DistSet (DistNumber)
    SELECT DISTINCT s.DistNumber
    FROM inserted i
    JOIN @CurrentLogs cl ON cl.LogEntry = i.LogEntry
    JOIN dbo.OSRN s
      ON s.ItemCode  = i.ItemCode
     AND s.SysNumber = i.SysNumber
    WHERE cl.StockQty > 0                -- ✅ enforce only on receipts
      AND s.DistNumber IS NOT NULL;

    -- 3) For each such DistNumber, find the latest PRIOR OITL row
    DECLARE @LatestPrior TABLE
    (
        DistNumber NVARCHAR(100) NOT NULL PRIMARY KEY,
        LogEntry   INT           NULL,
        BaseEntry  INT           NULL,
        DocType    INT           NULL,
        StockQty   NUMERIC(19,6) NULL
    );

    INSERT INTO @LatestPrior (DistNumber, LogEntry, BaseEntry, DocType, StockQty)
    SELECT
        ds.DistNumber,
        x.LogEntry,
        x.BaseEntry,
        x.DocType,
        x.StockQty
    FROM @DistSet ds
    OUTER APPLY
    (
        SELECT TOP (1)
               o.LogEntry,
               o.BaseEntry,
               o.DocType,
               o.StockQty
        FROM dbo.OITL o
        JOIN dbo.ITL1 i1
          ON i1.LogEntry = o.LogEntry
        JOIN dbo.OSRN s2
          ON s2.ItemCode  = i1.ItemCode
         AND s2.SysNumber = i1.SysNumber
        WHERE s2.DistNumber = ds.DistNumber
          AND NOT EXISTS (SELECT 1 FROM @CurrentLogs cl WHERE cl.LogEntry = o.LogEntry) -- exclude current posting
        ORDER BY o.LogEntry DESC, i1.ItemCode, i1.SysNumber
    ) AS x;

    -- 4) Block only if prior latest row matches your rule
    DECLARE @BadDist NVARCHAR(100);
    SELECT TOP (1) @BadDist = DistNumber
    FROM @LatestPrior
    WHERE LogEntry IS NOT NULL
      AND ISNULL(BaseEntry, 0) = 0
      AND NOT (DocType = 10000071 AND StockQty < 0)   -- your exception
    ORDER BY DistNumber;

    IF @BadDist IS NOT NULL
    BEGIN
        DECLARE @msg NVARCHAR(2048) =
            N'აღნიშნული სერიული ნომერი უკვე გამოყენებულია. DistNumber: ' + @BadDist;
        THROW 50001, @msg, 1;
    END
END
