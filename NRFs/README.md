# NRF templates and data licence

A neurodynamic response function (NRF) is a predefined temporal response shape
fitted to the EEG to estimate response magnitude. The three templates below
are supplied in `simple`, `simple-oxford`, and `simple-strasbourg`; corresponding
files are identical across those repositories.

| Template file | Response | Source study |
| --- | --- | --- |
| [early_NRF_500Hz.mat](early_NRF_500Hz.mat) | Early sensory response (e-NRF) | [Cobo et al. (2022)](https://doi.org/10.1038/s41467-022-31505-y) |
| [noxious_NRF_500Hz.mat](noxious_NRF_500Hz.mat) | Later noxious-evoked response (n-NRF) | [Hartley et al. (2017)](https://doi.org/10.1126/scitranslmed.aah6122) |
| [noxious_preterm_NRF_500Hz.mat](noxious_preterm_NRF_500Hz.mat) | Preterm noxious response (p-NRF) | [van der Vaart et al. (2022)](https://doi.org/10.1093/cercor/bhab449) |

These three MAT files are licensed under **Creative Commons Attribution 4.0
International (CC BY 4.0)**. The same licence covers the numerical test data in
[`tests/fixtures/simple_scientific_oracle_v1.mat`](../tests/fixtures/simple_scientific_oracle_v1.mat),
including its NRF-derived arrays. See the [licence text](LICENSE).

You may copy, adapt, and redistribute these data, including commercially.
When reusing a template, credit its source study above and the SIMPLE
repository from which you obtained it, link to
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), and indicate any
changes. For reuse of the test data, credit the source repository and retain
the relevant template attribution.

The [NRF configuration file](nrf_config.ini), software, test scripts, and
associated documentation remain under the repository's
[Apache License 2.0](../LICENSE).
