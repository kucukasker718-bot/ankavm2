package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"clicd/internal/config"
)

func TestHandleRoutingGetAllowsRoutingWriteScope(t *testing.T) {
	config.AppConfig = &config.ClicdConfig{}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/routing", nil)
	req = withAuthContext(req, AuthContext{
		Type:   authTypeAPIKey,
		Scopes: []string{"routing:write"},
	})
	rec := httptest.NewRecorder()

	handleRoutingGet(rec, req)

	if rec.Code == http.StatusForbidden {
		t.Fatal("routing:write scope should be able to receive the routing response after updates")
	}
}
