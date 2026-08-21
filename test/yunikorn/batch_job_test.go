package yunikorn_test

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

	err = utils.WaitJobsCompleted(t.Context(), utils.Resources, "bench-yunikorn",
		provider.QueueSize*provider.JobsSizePerQueue+
			provider.ImpactingQueuesSize*provider.ImpactingJobsSizePerQueue+
			provider.CriticalQueuesSize*provider.CriticalJobsSizePerQueue)
	if err != nil {
		t.Fatal(err)
	}
}
