package kueue_test

import (
	"testing"

	"github.com/wzshiming/kube-scheduling-perf/test/utils"
)

func TestInit(t *testing.T) {
	err := provider.InitCase(t.Context())
	if err != nil {
		t.Fatal(err)
	}
}

func TestBatchJob(t *testing.T) {
	err := provider.AddJobs(t.Context())
	if err != nil {
		t.Fatal(err)
	}

	err = utils.WaitDeployment(t.Context(), utils.Resources, "bench-kueue")
	if err != nil {
		t.Fatal(err)
	}
}
