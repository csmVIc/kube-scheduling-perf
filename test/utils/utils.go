package utils

import (
	"bytes"
	"context"
	"fmt"
	"reflect"
	"sync"
	"sync/atomic"
	"text/template"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
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

// CreateOrUpdateConfigMapsHandler updates existing ConfigMaps in place and
// creates all other decoded objects with the existing behavior.
func CreateOrUpdateConfigMapsHandler(r *resources.Resources, configChanged *bool) func(context.Context, k8s.Object) error {
	return func(ctx context.Context, obj k8s.Object) error {
		configMap, ok := obj.(*corev1.ConfigMap)
		if !ok {
			return r.Create(ctx, obj)
		}

		current := &corev1.ConfigMap{}
		err := r.Get(ctx, configMap.Name, configMap.Namespace, current)
		if apierrors.IsNotFound(err) {
			*configChanged = true
			return r.Create(ctx, configMap)
		}
		if err != nil {
			return err
		}

		if reflect.DeepEqual(current.Data, configMap.Data) &&
			reflect.DeepEqual(current.BinaryData, configMap.BinaryData) {
			return nil
		}

		current.Data = configMap.Data
		current.BinaryData = configMap.BinaryData
		*configChanged = true
		return r.Update(ctx, current)
	}
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

func WaitJobsCompleted(ctx context.Context, r *resources.Resources, namespace string, expected int) error {
	namespacedResources, err := resources.New(r.GetConfig())
	if err != nil {
		return err
	}
	namespacedResources.WithNamespace(namespace)

	return wait.For(func(ctx context.Context) (bool, error) {
		var jobs batchv1.JobList
		if err := namespacedResources.List(ctx, &jobs); err != nil {
			return false, err
		}
		if len(jobs.Items) != expected {
			return false, nil
		}

		for i := range jobs.Items {
			completed := false
			for _, condition := range jobs.Items[i].Status.Conditions {
				if condition.Type == batchv1.JobComplete && condition.Status == corev1.ConditionTrue {
					completed = true
					break
				}
			}
			if !completed {
				return false, nil
			}
		}
		return true, nil
	}, wait.WithInterval(10*time.Second), wait.WithTimeout(time.Hour))
}

func TimesQuantity(q resource.Quantity, t int) *resource.Quantity {
	o := q.DeepCopy()
	for range t - 1 {
		o.Add(q)
	}
	return &o
}
