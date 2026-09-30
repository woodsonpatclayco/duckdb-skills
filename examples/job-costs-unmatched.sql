-- examples\job-costs-unmatched.sql
--
-- GL rows (lake.Clayco_Job_Costs_from_GL) whose parent project is missing
-- from the Snowflake extract (extract_table('parent_projects')) -- the check
-- a stale extract fails first: a project created in Snowflake after the
-- extract was taken shows up here even though the join above quietly drops
-- it. A non-zero count here, alongside a stale=true EXTRACT line, is the
-- signal to refresh the extract through the snowflake-extract skill before
-- trusting the joined totals.
SELECT g.PARENT_PROJECT_NUMBER, count(*) AS gl_rows, sum(g.JOB_COSTS) AS job_costs
FROM lake.Clayco_Job_Costs_from_GL g
ANTI JOIN extract_table('parent_projects') p USING (PARENT_PROJECT_NUMBER)
GROUP BY ALL
ORDER BY job_costs DESC
