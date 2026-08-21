package volcano_test

import (
	"testing"
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

	err = provider.WaitJobsCompleted(t.Context())
	if err != nil {
		t.Fatal(err)
	}
}
