-- Snowflake-managed MCP server quickstart setup.
-- Creates a warehouse, database, and schema, loads sample financial services data from AWS S3,
-- creates the SEND_EMAIL stored procedure used later as a custom MCP tool, and creates a
-- least-privileged role for MCP clients.

use role accountadmin;

-- OPTIONAL: enable cross-region inference if supported models aren't available in your region
-- alter account set cortex_enabled_cross_region = 'ANY_REGION';

create database if not exists dash_mcp_db;
create schema if not exists dash_mcp_db.data;
create warehouse if not exists dash_wh_s warehouse_size=small;

use dash_mcp_db.data;
use warehouse dash_wh_s;
  
create or replace file format mcp_csvformat  
  skip_header = 1  
  field_optionally_enclosed_by = '"'  
  type = 'csv';  

create or replace table dim_customers (
    customer_id varchar(10) not null,
    first_name varchar(50) not null,
    last_name varchar(50) not null,
    email varchar(100) not null,
    phone varchar(30),
    date_of_birth date,
    ssn_hash varchar(32),
    address varchar(200),
    city varchar(50),
    state varchar(2),
    zip_code varchar(10),
    region varchar(20),
    customer_segment varchar(20),
    credit_score number(3,0),
    annual_income number(10,2),
    net_worth number(12,2),
    join_date date,
    status varchar(20),
    acquisition_channel varchar(30),
    lifetime_value number(10,2),
    risk_profile varchar(10),
    constraint uk_dim_customers_email unique (email),
    constraint pk_dim_customers primary key (customer_id)
);

create or replace stage customers_data_stage  
  file_format = mcp_csvformat  
  url = 's3://sfquickstarts/sfguide-getting-started-with-snowflake-mcp-server/customers/';  

copy into dim_customers
  from @customers_data_stage;

create or replace stage campaigns_data_stage  
  file_format = mcp_csvformat  
  url = 's3://sfquickstarts/sfguide-getting-started-with-snowflake-mcp-server/campaigns/';

create or replace table dim_campaigns (
    campaign_id varchar(10) not null,
    campaign_name varchar(200) not null,
    campaign_type varchar(20),
    objective varchar(20),
    product_promoted varchar(8),
    start_date date,
    end_date date,
    budget number(12,2),
    actual_spend number(12,2),
    target_audience varchar(20),
    target_region varchar(20),
    impressions number(10,0),
    clicks number(8,0),
    conversions number(8,0),
    revenue_generated number(12,2),
    roi number(8,2),
    status varchar(20),
    constraint pk_dim_campaigns primary key (campaign_id)
);

copy into dim_campaigns  
  from @campaigns_data_stage;

create or replace stage marketing_data_stage  
  file_format = mcp_csvformat  
  url = 's3://sfquickstarts/sfguide-getting-started-with-snowflake-mcp-server/marketing/';

create or replace table fact_marketing_responses (
    response_id varchar(12) not null,
    customer_id varchar(10) not null,
    campaign_id varchar(10) not null,
    contacted_date date not null,
    geo_id varchar(8),
    response_type varchar(20),
    conversion_value number(10,2) default 0,
    channel_used varchar(20),
    engagement_score number(3,0),
    constraint pk_fact_marketing_responses primary key (response_id),
    constraint fk_mkt_customer foreign key (customer_id) references dim_customers(customer_id),
    constraint fk_mkt_campaign foreign key (campaign_id) references dim_campaigns(campaign_id)
);

copy into fact_marketing_responses
  from @marketing_data_stage;

create or replace stage risk_assessments_data_stage  
  file_format = mcp_csvformat  
  url = 's3://sfquickstarts/sfguide-getting-started-with-snowflake-mcp-server/risk_assessment/';

create or replace table fact_risk_assessments (
	assessment_id varchar(10) not null,
	customer_id varchar(10) not null,
	assessment_date date not null,
	credit_risk_score number(5,2),
	fraud_risk_score number(5,2),
	aml_risk_score number(5,2),
	overall_risk_rating varchar(15),
	risk_factors varchar(500),
	review_required number(1,0) default 0,
	last_review_date date,
	next_review_date date,
	constraint pk_fact_risk_assessments primary key (assessment_id),
	constraint fk_risk_customer foreign key (customer_id) references dim_customers(customer_id)
);

copy into fact_risk_assessments
  from @risk_assessments_data_stage;

create or replace stage transactions_data_stage
  file_format = mcp_csvformat
  url = 's3://sfquickstarts/sfguide-getting-started-with-snowflake-mcp-server/transactions/';

create or replace table fact_transactions (
    transaction_id varchar(16777216),
    account_id varchar(16777216),
    customer_id varchar(16777216),
    transaction_date timestamp_ntz(9),
    transaction_type varchar(16777216),
    amount number(38,2),
    balance_after number(38,2),
    merchant_name varchar(16777216),
    merchant_category varchar(16777216),
    channel varchar(16777216),
    location varchar(16777216),
    description varchar(16777216),
    is_flagged number(38,0),
    fraud_score number(38,2)
);

copy into fact_transactions
  from @transactions_data_stage;

create or replace stage support_data_stage
  file_format = mcp_csvformat
  url = 's3://sfquickstarts/sfguide-getting-started-with-snowflake-mcp-server/support/';

create or replace table fact_support_tickets (
    ticket_id varchar(11) not null,
    customer_id varchar(10) not null,
    account_id varchar(10),
    created_date date not null,
    geo_id varchar(8),
    category varchar(30),
    subcategory varchar(50),
    priority varchar(10),
    channel varchar(20),
    subject varchar(500),
    description varchar(1000),
    status varchar(20),
    assigned_agent varchar(8),
    resolution_date date,
    resolution_time_hours number(8,2),
    satisfaction_score number(1,0),
    first_response_time_minutes number(8,2),
    constraint pk_fact_support_tickets primary key (ticket_id),
    constraint fk_support_customer foreign key (customer_id) references dim_customers(customer_id)
);

copy into fact_support_tickets
  from @support_data_stage;

-- Internal stage for the semantic view YAML file (optional; Semantic View Autopilot can also upload it directly).
create or replace stage semantic_models encryption = (type = 'snowflake_sse') directory = ( enable = true );

create or replace notification integration email_integration
  type=email
  enabled=true
  default_subject = 'Snowflake MCP Server';

create or replace procedure send_email(
    recipient_email varchar,
    subject varchar,
    body varchar
)
returns varchar
language python
runtime_version = '3.12'
packages = ('snowflake-snowpark-python')
handler = 'send_email'
as
$$
def send_email(session, recipient_email, subject, body):
    try:
        # Use bind parameters so agent-supplied values can't alter the SQL
        session.sql(
            "CALL SYSTEM$SEND_EMAIL('email_integration', ?, ?, ?, 'text/html')",
            params=[recipient_email, subject, body]
        ).collect()
        
        return "Email sent successfully"
    except Exception as e:
        return f"Error sending email: {str(e)}"
$$;

-- Least-privileged role for MCP clients. The programmatic access token (PAT) you create in the guide is
-- restricted to this role, so MCP clients never run with ACCOUNTADMIN privileges. Grants on the Cortex Search
-- service, semantic view, and MCP server are added in the guide after those objects exist.
create role if not exists dash_mcp_role;
grant database role snowflake.cortex_user to role dash_mcp_role;
grant usage on warehouse dash_wh_s to role dash_mcp_role;
grant usage on database dash_mcp_db to role dash_mcp_role;
grant usage on schema dash_mcp_db.data to role dash_mcp_role;
grant select on all tables in schema dash_mcp_db.data to role dash_mcp_role;
grant usage on procedure dash_mcp_db.data.send_email(varchar, varchar, varchar) to role dash_mcp_role;

set current_user = (select current_user());
grant role dash_mcp_role to user identifier($current_user);

select 'Congratulations! The setup is complete. You can now proceed to the next step in the guide.' as message;
