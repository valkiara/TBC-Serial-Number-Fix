GO
/****** Object:  Trigger [dbo].[trg_OSRN_BlockOnUpdate]    Script Date: 10.10.2025 15:31:33 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   TRIGGER [dbo].[trg_OSRN_BlockOnUpdate]
ON [dbo].[OSRN]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Collect only rows where DistNumber actually changed
    DECLARE @Changed TABLE
    (
        AbsEntry       INT           NOT NULL,
        ItemCode       NVARCHAR(50)  NULL,
        NewDistNumber  NVARCHAR(100) NULL
    );

    INSERT INTO @Changed (AbsEntry, ItemCode, NewDistNumber)
    SELECT DISTINCT i.AbsEntry, i.ItemCode, i.DistNumber
    FROM inserted i
    JOIN deleted  d ON d.AbsEntry = i.AbsEntry
    WHERE ISNULL(i.DistNumber, N'') <> ISNULL(d.DistNumber, N'');

    IF NOT EXISTS (SELECT 1 FROM @Changed) RETURN;

    ----------------------------------------------------------------
    -- Pick one violating NewDistNumber (if any)
    -- Violation definition:
    --   1) The NEW serial already exists on a different OSRN row, AND
    --   2) That serial’s latest OITL is NOT “cancelled”:
    --        - Latest.BaseEntry = 0
    --        - AND it's NOT an Inventory Posting removal
    --          (DocType = 10000071 AND StockQty < 0)
    ----------------------------------------------------------------
    DECLARE @BadNewDistNumber NVARCHAR(100);

    SELECT TOP (1)
        @BadNewDistNumber = c.NewDistNumber
    FROM @Changed c
    WHERE c.NewDistNumber IS NOT NULL AND c.NewDistNumber <> N''
      AND EXISTS (   -- NEW serial exists on some other OSRN row
            SELECT 1
            FROM dbo.OSRN x
            WHERE x.DistNumber = c.NewDistNumber
              AND x.AbsEntry  <> c.AbsEntry
      )
      AND EXISTS (   -- That serial's latest OITL is NOT cancelled
            SELECT 1
            FROM (
                SELECT TOP (1)
                       T0.LogEntry,
                       T0.BaseEntry,
                       T0.DocType,
                       T0.StockQty
                FROM OITL AS T0
                JOIN ITL1 AS T1
                  ON T1.LogEntry = T0.LogEntry
                JOIN OSRN AS T2
                  ON T2.SysNumber = T1.SysNumber
                 AND T2.ItemCode  = T1.ItemCode
                WHERE T2.DistNumber = c.NewDistNumber
                ORDER BY T0.LogEntry DESC
            ) AS Latest
            WHERE ISNULL(Latest.BaseEntry, 0) = 0
              AND NOT (Latest.DocType = 10000071 AND Latest.StockQty < 0)
      );

    IF @BadNewDistNumber IS NOT NULL
    BEGIN
        DECLARE @msg NVARCHAR(400) =
            N'აღნიშნული სერიული ნომერი უკვე გამოყენებულია. DistNumber: '
            + @BadNewDistNumber;
        THROW 50001, @msg, 1;
    END
END
