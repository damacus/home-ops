package clusterhealth

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"
)

func (c *Checker) CNPGClusters(ctx context.Context) Result {
	clusters, err := kubectlJSON[objectList[cnpgCluster]](ctx, c, "get", "clusters.postgresql.cnpg.io", "-A")
	if err != nil {
		return c.failedResult("cnpg-clusters", err)
	}
	bad := []string{}
	for _, cluster := range clusters.Items {
		instances := cluster.Status.Instances
		if instances == 0 {
			instances = cluster.Spec.Instances
		}
		if cluster.Status.Phase != "Cluster in healthy state" || cluster.Status.ReadyInstances != instances {
			bad = append(
				bad,
				fmt.Sprintf(
					"%s/%s: %s, ready %d/%d",
					cluster.Metadata.Namespace,
					cluster.Metadata.Name,
					cluster.Status.Phase,
					cluster.Status.ReadyInstances,
					instances,
				),
			)
		}
	}
	return NewResult(
		"cnpg-clusters",
		len(bad) > 0,
		"all CNPG clusters healthy",
		fmt.Sprintf("%d CNPG clusters unhealthy", len(bad)),
		bad,
	)
}

func (c *Checker) CNPGBackups(ctx context.Context) Result {
	backups, err := kubectlJSON[objectList[cnpgBackup]](ctx, c, "get", "backups.postgresql.cnpg.io", "-A")
	if err != nil {
		return c.failedResult("cnpg-backups", err)
	}
	clusters, err := kubectlJSON[objectList[cnpgCluster]](ctx, c, "get", "clusters.postgresql.cnpg.io", "-A")
	if err != nil {
		return c.failedResult("cnpg-backups", err)
	}
	schedules, err := kubectlJSON[objectList[cnpgScheduledBackup]](
		ctx,
		c,
		"get", "scheduledbackups.postgresql.cnpg.io", "-A",
	)
	if err != nil {
		return c.failedResult("cnpg-backups", err)
	}

	byCluster := map[string][]cnpgBackup{}
	for _, backup := range backups.Items {
		key := backup.Metadata.Namespace + "/" + backup.Spec.Cluster.Name
		byCluster[key] = append(byCluster[key], backup)
	}
	configuredClusters := map[string]struct{}{}
	for _, schedule := range schedules.Items {
		key := schedule.Metadata.Namespace + "/" + schedule.Spec.Cluster.Name
		configuredClusters[key] = struct{}{}
	}

	bad := []string{}
	details := []string{}
	for _, cluster := range clusters.Items {
		namespace := cluster.Metadata.Namespace
		name := cluster.Metadata.Name
		key := namespace + "/" + name
		if clusterHibernated(cluster) {
			details = append(details, key+": hibernated, backup/WAL check skipped")
			continue
		}
		if _, configured := configuredClusters[key]; !configured {
			details = append(details, key+": no ScheduledBackup configured, backup/WAL check skipped")
			continue
		}
		clusterBackups := byCluster[key]
		sort.Slice(clusterBackups, func(i, j int) bool {
			return backupStart(clusterBackups[i]).Before(backupStart(clusterBackups[j]))
		})

		var latest *cnpgBackup
		var latestSuccess *cnpgBackup
		if len(clusterBackups) > 0 {
			latest = &clusterBackups[len(clusterBackups)-1]
			for index := len(clusterBackups) - 1; index >= 0; index-- {
				if clusterBackups[index].Status.Phase == "completed" {
					latestSuccess = &clusterBackups[index]
					break
				}
			}
		}

		latestPhase := "missing"
		if latest != nil {
			latestPhase = latest.Status.Phase
			if latestPhase == "" {
				latestPhase = "unknown"
			}
		}
		latestSuccessTime := ""
		if latestSuccess != nil {
			latestSuccessTime = latestSuccess.Status.StoppedAt
		}
		if latestSuccessTime != "" {
			age, ageErr := c.age(latestSuccessTime)
			if ageErr != nil {
				bad = append(bad, key+": "+ageErr.Error())
			} else {
				details = append(
					details,
					fmt.Sprintf(
						"%s: latest=%s, last_success=%s (age=%.1f hours)",
						key,
						latestPhase,
						latestSuccessTime,
						age.Hours(),
					),
				)
			}
		} else {
			details = append(details, fmt.Sprintf("%s: latest=%s, last_success=-", key, latestPhase))
		}

		switch {
		case latest == nil:
			bad = append(bad, key+": no Backup resources found")
		case latest.Status.Phase == "failed":
			message := latest.Status.Error
			if message == "" {
				message = "unknown error"
			}
			bad = append(bad, fmt.Sprintf("%s: latest backup failed: %s", key, message))
		case latest.Status.Phase == "started":
			startedAt := latest.Status.StartedAt
			if startedAt == "" {
				startedAt = latest.Metadata.CreationTimestamp
			}
			age, ageErr := c.age(startedAt)
			if ageErr != nil {
				bad = append(bad, key+": "+ageErr.Error())
			} else if age > staleBackupAge {
				bad = append(bad, fmt.Sprintf("%s: latest backup still started since %s", key, startedAt))
			}
		}

		switch {
		case latestSuccess == nil:
			bad = append(bad, key+": no successful backup found")
		case latestSuccessTime == "":
			bad = append(bad, key+": last successful backup has no completion timestamp")
		default:
			age, ageErr := c.age(latestSuccessTime)
			if ageErr == nil && age > maxBackupAge {
				bad = append(
					bad,
					fmt.Sprintf(
						"%s: last successful backup is %.1f hours old (maximum %.0f hours)",
						key,
						age.Hours(),
						maxBackupAge.Hours(),
					),
				)
			}
		}

		archiver := c.ArchiveStatus(ctx, namespace, name)
		if archiver.Failed() {
			bad = append(bad, archiver.Details...)
		} else {
			details = append(details, archiver.Details...)
		}
	}

	return NewResult(
		"cnpg-backups",
		len(bad) > 0,
		"all configured CNPG backups and WAL archiving healthy",
		fmt.Sprintf("%d CNPG backup/WAL issues", len(bad)),
		append(bad, details...),
	)
}

func clusterHibernated(cluster cnpgCluster) bool {
	if cluster.Metadata.Annotations[hibernationAnnotation] == "on" {
		return true
	}
	for _, current := range cluster.Status.Conditions {
		if current.Type == hibernationAnnotation && current.Status == "True" {
			return true
		}
	}
	return false
}

func backupStart(backup cnpgBackup) time.Time {
	value := backup.Status.StartedAt
	if value == "" {
		value = backup.Metadata.CreationTimestamp
	}
	parsed, _ := time.Parse(time.RFC3339, value)
	return parsed
}

func (c *Checker) ArchiveStatus(ctx context.Context, namespace, name string) Result {
	output := c.Runner.Run(ctx, "kubectl", "cnpg", "status", "-n", namespace, name)
	if output.ExitCode != 0 {
		return Result{
			Name:    "cnpg-wal",
			Status:  StatusFail,
			Summary: "cnpg status failed",
			Details: []string{
				fmt.Sprintf("%s/%s: %s", namespace, name, outputMessage(output, "cnpg status failed")),
			},
		}
	}
	waiting := ""
	failing := false
	for _, line := range strings.Split(output.Stdout, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Working WAL archiving:") {
			failing = strings.Contains(line, "Failing")
		}
		if strings.HasPrefix(line, "WALs waiting to be archived:") {
			parts := strings.Split(line, ":")
			waiting = strings.TrimSpace(parts[len(parts)-1])
		}
	}
	details := []string{}
	if failing {
		details = append(details, fmt.Sprintf("%s/%s: WAL archiving failing", namespace, name))
	}
	walsWaiting := waiting != "" && waiting != "0"
	if walsWaiting {
		details = append(details, fmt.Sprintf("%s/%s: %s WALs waiting", namespace, name, waiting))
	}
	return NewResult(
		"cnpg-wal",
		failing || walsWaiting,
		"WAL archiving checked",
		"WAL archiving unhealthy",
		details,
	)
}
