USE [LiloMallTest ]
GO
/****** Object:  Trigger [dbo].[trg_OSRN_BlockOnUpdate]    Script Date: 31.10.2025 13:48:22 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER TRIGGER [dbo].[trg_OSRN_BlockOnUpdate]
ON [dbo].[OSRN]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- 1) Rows where DistNumber actually changed
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

    /* --------------------------------------------------------------------
       Heuristic:
       - PosCancelTypes: (13,15,19,67)  -> cancellation if StockQty > 0
       - NegCancelTypes: NOT IN above   -> cancellation if StockQty < 0
       Block if:
         A) Latest prior is cancellation AND DocType IN (13,15,19,67)
         OR
         B) Latest prior is NOT cancellation, except (DocType=10000071 AND StockQty<0)
       -------------------------------------------------------------------- */

    DECLARE @BadNewDistNumber NVARCHAR(100);

    SELECT TOP (1)
        @BadNewDistNumber = c.NewDistNumber
    FROM @Changed c
    WHERE c.NewDistNumber IS NOT NULL
      AND c.NewDistNumber <> N''
      AND EXISTS
      (
          -- NEW serial already exists on a different OSRN row
          SELECT 1
          FROM dbo.OSRN WITH (UPDLOCK, HOLDLOCK)
          WHERE DistNumber = c.NewDistNumber
            AND AbsEntry  <> c.AbsEntry
      )
      AND EXISTS
      (
          -- That serial's latest prior OITL row violates the rules
          SELECT 1
          FROM
          (
              SELECT TOP (1)
                     o.LogEntry,
                     o.DocType,
                     o.StockQty
              FROM dbo.OITL o
              JOIN dbo.ITL1 i1
                ON i1.LogEntry = o.LogEntry
              JOIN dbo.OSRN s2
                ON s2.SysNumber = i1.SysNumber
               AND s2.ItemCode  = i1.ItemCode
              WHERE LTRIM(RTRIM(s2.DistNumber)) = LTRIM(RTRIM(c.NewDistNumber))
              ORDER BY o.LogEntry DESC
          ) AS Latest
          WHERE
          (
              -- A) Prior is cancellation AND DocType in (13,15,19,67) -> BLOCK
              (
                  (
                       (Latest.DocType IN (13,15,19,67) AND Latest.StockQty > 0)
                    OR (Latest.DocType NOT IN (13,15,19,67) AND Latest.StockQty < 0)
                  )
                  AND Latest.DocType IN (13,15,19,67)
              )
              OR
              -- B) Prior NOT cancellation -> BLOCK, except explicit exception
              (
                  NOT (
                       (Latest.DocType IN (13,15,19,67) AND Latest.StockQty > 0)
                    OR (Latest.DocType NOT IN (13,15,19,67) AND Latest.StockQty < 0)
                  )
                  AND NOT (Latest.DocType = 10000071 AND Latest.StockQty < 0)
              )
          )
      );

    IF @BadNewDistNumber IS NOT NULL
    BEGIN
        DECLARE @msg NVARCHAR(400);
        SET @msg = N'აღნიშნული სერიული ნომერი უკვე გამოყენებულია. DistNumber: ' + @BadNewDistNumber;
        THROW 50001, @msg, 1;
    END
END
