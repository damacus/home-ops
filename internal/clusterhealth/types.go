package clusterhealth

type objectList[T any] struct {
	Items []T `json:"items"`
}

type metadata struct {
	Name              string            `json:"name"`
	Namespace         string            `json:"namespace"`
	CreationTimestamp string            `json:"creationTimestamp"`
	Annotations       map[string]string `json:"annotations"`
}

type condition struct {
	Type               string `json:"type"`
	Status             string `json:"status"`
	Reason             string `json:"reason"`
	Message            string `json:"message"`
	LastTransitionTime string `json:"lastTransitionTime"`
}

type node struct {
	Metadata metadata `json:"metadata"`
	Status   struct {
		Conditions []condition `json:"conditions"`
	} `json:"status"`
}

type containerStatus struct {
	Ready bool `json:"ready"`
	State struct {
		Waiting struct {
			Reason string `json:"reason"`
		} `json:"waiting"`
	} `json:"state"`
}

type pod struct {
	Metadata metadata `json:"metadata"`
	Spec     struct {
		ServiceAccountName string `json:"serviceAccountName"`
	} `json:"spec"`
	Status struct {
		Phase             string            `json:"phase"`
		ContainerStatuses []containerStatus `json:"containerStatuses"`
	} `json:"status"`
}

type deployment struct {
	Metadata metadata `json:"metadata"`
	Spec     struct {
		Replicas *int `json:"replicas"`
	} `json:"spec"`
	Status struct {
		ReadyReplicas     int `json:"readyReplicas"`
		AvailableReplicas int `json:"availableReplicas"`
	} `json:"status"`
}

type serviceAccount struct {
	Metadata metadata `json:"metadata"`
}

type readinessResource struct {
	Metadata metadata `json:"metadata"`
	Spec     struct {
		Suspend bool `json:"suspend"`
	} `json:"spec"`
	Status struct {
		Conditions []condition `json:"conditions"`
	} `json:"status"`
}

type cnpgCluster struct {
	Metadata metadata `json:"metadata"`
	Spec     struct {
		Instances int `json:"instances"`
	} `json:"spec"`
	Status struct {
		Instances      int         `json:"instances"`
		ReadyInstances int         `json:"readyInstances"`
		Phase          string      `json:"phase"`
		Conditions     []condition `json:"conditions"`
	} `json:"status"`
}

type cnpgBackup struct {
	Metadata metadata `json:"metadata"`
	Spec     struct {
		Cluster struct {
			Name string `json:"name"`
		} `json:"cluster"`
	} `json:"spec"`
	Status struct {
		Phase     string `json:"phase"`
		Error     string `json:"error"`
		StartedAt string `json:"startedAt"`
		StoppedAt string `json:"stoppedAt"`
	} `json:"status"`
}

type prometheusResponse struct {
	Data struct {
		Result []struct {
			Metric map[string]string `json:"metric"`
		} `json:"result"`
	} `json:"data"`
}

type alertmanagerAlert struct {
	Status struct {
		State string `json:"state"`
	} `json:"status"`
	Labels map[string]string `json:"labels"`
}

type lokiResponse struct {
	Data struct {
		Result []struct {
			Metric map[string]string `json:"metric"`
			Value  []any             `json:"value"`
		} `json:"result"`
	} `json:"data"`
}
