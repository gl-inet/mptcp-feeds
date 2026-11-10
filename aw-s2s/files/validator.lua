return {
    IPRB_req_secondary_rename = { aliasName = "^.*$" },
    IPRB_set_access_code_alias = { alias = "^.*$" },
    IPRB_set_primary_alias = { alias = "^.*$" },
    raw_request = {
        req_body = {
            aliasName = "^.*$",
            clientAlias = "^.*$"
        },
        query_params = {
            sort = "^[%w%_%-%,]+$"
        }
    }
}
