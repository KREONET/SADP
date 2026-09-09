package main

import (
	"net/http"
)

func newHandler(api *apiServer) http.Handler {
	openAPI, err := assets.ReadFile("openapi.yaml")
	if err != nil {
		panic(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /api/v1/health", handleAPIHealth)
	mux.HandleFunc("GET /api/v1/catalog", api.handleCatalog)
	mux.HandleFunc("POST /api/v1/app-profiles/validate", api.handleAppProfileValidation)
	mux.HandleFunc("POST /api/v1/app-groups/validate", api.handleAppGroupValidation)
	mux.HandleFunc("POST /api/v1/app-groups", api.handleCreateAppGroup)
	mux.HandleFunc("GET /api/v1/openapi.yaml", openAPIHandler(openAPI))
	mux.HandleFunc("POST /api/v1/deployment-requests", api.handleCreateDeploymentRequest)
	mux.HandleFunc("GET /api/v1/deployment-requests", api.handleListDeploymentRequests)
	mux.HandleFunc("GET /api/v1/deployment-requests/{requestID}", api.handleGetDeploymentRequest)
	mux.HandleFunc("PUT /api/v1/deployment-requests/{requestID}/runtime-state", api.handleUpdateRuntimeState)
	mux.HandleFunc("DELETE /api/v1/deployment-requests/{requestID}", api.handleDeleteDeploymentRequest)
	mux.HandleFunc("GET /api/v1/admin/approval-dashboard", api.handleAdminApprovalDashboard)
	mux.HandleFunc("POST /api/v1/admin/deployment-requests/{requestID}/decision", api.handleAdminApprovalDecision)
	mux.HandleFunc("PUT /api/v1/admin/approval-policies/{requester}", api.handleAdminApprovalPolicy)
	mux.HandleFunc("GET /api/v1/quota-usage", api.handleQuotaUsage)
	return secure(mux)
}
