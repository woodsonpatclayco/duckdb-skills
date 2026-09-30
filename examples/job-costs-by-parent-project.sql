-- examples\job-costs-by-parent-project.sql
--
-- Job costs from the GL (workbook sheet, via lake.Clayco_Job_Costs_from_GL)
-- joined to parent-project names and WIP status from the Snowflake extract
-- (extract_table('parent_projects')), by parent project, largest job costs
-- first. Run through tools\cross-query.ps1 so the age of both inputs prints
-- beside the answer -- never hand-write this join without the runner, since
-- nothing else prints the extract's or the workbook's age automatically.
SELECT g.PARENT_PROJECT_NUMBER, p.PARENT_PROJECT_NAME, p.PARENT_WIP_STATUS,
       count(*) AS gl_rows, sum(g.JOB_COSTS) AS job_costs
FROM lake.Clayco_Job_Costs_from_GL g
JOIN extract_table('parent_projects') p USING (PARENT_PROJECT_NUMBER)
GROUP BY ALL
ORDER BY job_costs DESC
