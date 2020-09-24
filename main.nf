// nextflow-rexmap pipelen
/*
NXF ver 19.08+ needed because of the use of tuple instead of set
*/
if( !nextflow.version.matches('>=19.08') ) {
    println "This workflow requires Nextflow version 19.08 or greater and you are running version $nextflow.version"
    exit 1
}

/* 
 * pipeline input parameters 
 */
params.fastqdir = "fastq"
params.outdir = "$workflow.launchDir/results-dada2"
params.fqpattern = "*_R{1,2}_001.fastq.gz"
params.region = "V4"
params.keep_fastq = false

params.help = ""

/* 
 * pipeline input parameters end
 */

//just in case trailing slash in readsdir not provided...
fastqdir_repaired = "${params.fastqdir}".replaceFirst(/$/, "/") 
fastqfiles = fastqdir_repaired + params.fqpattern

// channel for fastq files --> merge and trim
Channel
    .fromFilePairs( fastqfiles, checkIfExists: true )
    .set { fastq_ch }

// step 1 --> merge reads and trim primers
process merge_and_trim {
    tag "$sample_id"
    publishDir "${params.outdir}/merged_trimmed_reads", enabled: params.keep_fastq, mode: 'copy', pattern: '*_{trimmed,merged}.fastq'
    
    input:
        tuple sample_id, file(x) from fastq_ch
    output:
        file '*_merged.fastq'
        file '*_trimmed.fastq' into mergetrim_ch1
        file '*_trimmed.fastq' into mergetrim_ch2 // 1 goes to fixed_len_trim, 2 goes to dada2
        file 'merge.csv' into merge_stats_ch
        file 'primertrim.csv' into trim_stats_ch
    script:
    """
    01_merge_and_trim.R --region ${params.region} ${x}
    """
}

// fixed len trimming is done on all files, collected from mergetrim_ch1, therefore a separate process
process fixed_len_trim {
    publishDir "${params.outdir}/merged_trimmed_reads", enabled: params.keep_fastq, mode: 'copy', pattern: '*_fltrimmed.fastq'
    publishDir "${params.outdir}/statistics", mode: 'copy', pattern: '*.{pdf,csv}'

    input:
        file x from mergetrim_ch1.collect()
    output:
        file '*_fltrimmed.fastq' into fltrim_ch
        file 'seqlen-fltrim-plot.pdf'
        file 'stats-fltrim.csv' into fltrim_stats_ch
    script:
    """
    02_fl_trim.R ${x}
    """
}

process dada2_asv {
    publishDir params.outdir, mode: 'copy', pattern: '*.csv'

    input:
        file fltrimmed from fltrim_ch
        file fluntrimmed from mergetrim_ch2.collect() // toSortedList?
    output:
        //file 'dada2_result.rds'
        file 'ab.dt' into ab_dt_ch
        file 'osu_abundances.csv' into osu_ab_ch
        file '*.csv' into dada2_ch
    script:
    """
    03_dada.R --fltrimmed ${fltrimmed} --fluntrimmed ${fluntrimmed} --region ${params.region}
    """
}

process read_counts_stats {
    publishDir "${params.outdir}/statistics", mode: 'copy'

    input:
        file 'merge*' from merge_stats_ch.collect()
        file 'primertrim*' from trim_stats_ch.collect()
        file 'stats-fltrim.csv' from fltrim_stats_ch
        file 'ab.dt' from ab_dt_ch
        file 'osu_abundances.csv' from osu_ab_ch
    output:
        file 'stats*.csv'
    script:
    """
    echo "sample_id, total_reads, low_pct_sim, low_aln_len" > stats-merge.csv
    cat merge* >> stats-merge.csv
    echo "sample_id, total, fwd_trim, rev_trim" > stats-primertrim.csv
    cat primertrim* >> stats-primertrim.csv
    stats-table.R \
        --stats_merge_file stats-merge.csv \
        --stats_fltrim_file stats-fltrim.csv \
        --ab_file ab.dt \
        --osu_ab_file osu_abundances.csv
    """
}

process construct_phyloseq {
    publishDir "${params.outdir}/phyloseq", mode: 'copy'

    input: 
        file x from dada2_ch //this is a list with the files arranged alphabetically
    output:
        file 'physeq.Rdata'
    script:
    """
    04_phyloseq.R --osu_ab ${x[0]} --osu_tax ${x[2]}
    """
}