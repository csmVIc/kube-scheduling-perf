package utils

import (
	"bytes"
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"text/template"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/e2e-framework/klient/k8s"
	"sigs.k8s.io/e2e-framework/klient/k8s/resources"
	"sigs.k8s.io/e2e-framework/klient/wait"
)

var (
	templateCache = map[string]*template.Template{}
	bufferPool    = sync.Pool{
		New: func() any {
			return bytes.NewBuffer(nil)
		},
	}
)

// YamlWithArgs renders yaml template with given arguments
func YamlWithArgs(t string, args map[string]any) string {
	tmpl, ok := templateCache[t]
	if !ok {
		tt, err := template.New("_").
			Delims("#{{", "}}").
			Parse(t)
		if err != nil {
			panic(err)
		}
		templateCache[t] = tt
		tmpl = tt
	}

	buf := bufferPool.Get().(*bytes.Buffer)
	buf.Reset()
	defer bufferPool.Put(buf)

	err := tmpl.Execute(buf, args)
	if err != nil {
		panic(err)
	}

	return buf.String()
}

var index uint64

func Index() uint64 {
	return atomic.AddUint64(&index, 1)
}

func RestartDeployment(ctx context.Context, r *resources.Resources, name, namespace string) error {
	deploy := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
		},
	}
	err := r.Get(ctx, deploy.Name, deploy.Namespace, deploy)
	if err != nil {
		return err
	}

	if deploy.Spec.Replicas == nil || *deploy.Spec.Replicas == 0 {
		return nil
	}

	desiredReplicas := *deploy.Spec.Replicas
	previousGeneration := deploy.Generation
	restartPatch := []byte(fmt.Sprintf(
		`{"spec":{"template":{"metadata":{"annotations":{"benchmark.scheduling/restartedAt":%q}}}}}`,
		time.Now().UTC().Format(time.RFC3339Nano),
	))
	err = r.Patch(ctx, deploy, k8s.Patch{types.MergePatchType, restartPatch})
	if err != nil {
		return err
	}

	err = wait.For(func(ctx context.Context) (bool, error) {
		current := &appsv1.Deployment{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: namespace,
			},
		}
		if err := r.Get(ctx, current.Name, current.Namespace, current); err != nil {
			return false, err
		}

		return current.Generation > previousGeneration &&
			current.Status.ObservedGeneration >= current.Generation &&
			current.Status.Replicas == desiredReplicas &&
			current.Status.UpdatedReplicas == desiredReplicas &&
			current.Status.ReadyReplicas == desiredReplicas &&
			current.Status.AvailableReplicas == desiredReplicas, nil
	},
		wait.WithInterval(time.Second),
		wait.WithTimeout(time.Minute*1))
	if err != nil {
		return err
	}
	return nil
}

func WaitDeployment(ctx context.Context, r *resources.Resources, namespace string) error {
	namespacedResources, err := resources.New(r.GetConfig())
	if err != nil {
		return err
	}
	namespacedResources.WithNamespace(namespace)

	var pods corev1.PodList
	return wait.For(func(context.Context) (done bool, err error) {
		err = namespacedResources.List(ctx, &pods,
			resources.WithLabelSelector(`test-instance == 1`),
			func(lo *metav1.ListOptions) {
				lo.Limit = 1
			},
		)
		if err != nil {
			return false, err
		}
		return len(pods.Items) == 0, nil
	},
		wait.WithInterval(10*time.Second),
		wait.WithTimeout(1*time.Hour),
	)
}

func TimesQuantity(q resource.Quantity, t int) *resource.Quantity {
	o := q.DeepCopy()
	for range t - 1 {
		o.Add(q)
	}
	return &o
}
