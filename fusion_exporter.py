#!/usr/bin/env python3
"""
Fusion Reactor Prometheus Exporter
Simulates live telemetry from the fusion_reactor JSON schema
and exposes metrics on :8000/metrics for Prometheus to scrape.
"""

import time
import math
import random
from prometheus_client import start_http_server, Gauge, Counter, Info

# ── Metadata ──────────────────────────────────────────────────────────────────
reactor_info = Info("fusion_reactor", "Static metadata about the reactor")
reactor_info.info({
    "reactor_id": "FRP-001",
    "facility_name": "National Fusion Research Center",
    "reactor_type": "Tokamak",
    "session_id": "SESSION-20260306-A",
})

# ── Plasma ────────────────────────────────────────────────────────────────────
plasma_temp_kev          = Gauge("fusion_plasma_temperature_keV",        "Plasma temperature in keV")
plasma_temp_K            = Gauge("fusion_plasma_temperature_kelvin",     "Plasma temperature in Kelvin")
plasma_density           = Gauge("fusion_plasma_density_per_m3",         "Plasma density per cubic meter")
plasma_pressure          = Gauge("fusion_plasma_pressure_pascals",       "Plasma pressure in Pascals")
plasma_confinement       = Gauge("fusion_plasma_confinement_time_s",     "Energy confinement time (tau_E) seconds")
plasma_beta              = Gauge("fusion_plasma_beta_value",             "Plasma beta (pressure / magnetic pressure)")
plasma_q_factor          = Gauge("fusion_plasma_q_factor",              "Fusion energy gain factor Q")
fusion_power             = Gauge("fusion_plasma_fusion_power_MW",        "Fusion power output in MW")
heating_power            = Gauge("fusion_plasma_heating_power_MW",       "External heating power in MW")
plasma_gain_Q            = Gauge("fusion_plasma_gain_Q",                "Ratio fusion_power / heating_power")
deuterium_pct            = Gauge("fusion_fuel_deuterium_percent",        "Deuterium fuel fraction percent")
tritium_pct              = Gauge("fusion_fuel_tritium_percent",          "Tritium fuel fraction percent")
impurity_carbon          = Gauge("fusion_impurity_carbon_ppm",           "Carbon impurity ppm")
impurity_oxygen          = Gauge("fusion_impurity_oxygen_ppm",           "Oxygen impurity ppm")
impurity_tungsten        = Gauge("fusion_impurity_tungsten_ppm",         "Tungsten impurity ppm")
helium_ash_pct           = Gauge("fusion_impurity_helium_ash_percent",   "Helium ash fraction percent")

# ── Magnetic Field ─────────────────────────────────────────────────────────────
toroidal_field           = Gauge("fusion_mag_toroidal_field_tesla",      "Toroidal magnetic field Tesla")
poloidal_field           = Gauge("fusion_mag_poloidal_field_tesla",      "Poloidal magnetic field Tesla")
plasma_current           = Gauge("fusion_mag_plasma_current_MA",         "Plasma current in mega-amperes")
disruption_risk          = Gauge("fusion_mag_disruption_risk_percent",   "Real-time disruption risk percent")
elm_frequency            = Gauge("fusion_mag_ELM_frequency_Hz",          "ELM frequency in Hz")

# ── Heating Systems ────────────────────────────────────────────────────────────
nbi_power                = Gauge("fusion_heat_nbi_power_MW",             "NBI power MW")
nbi_efficiency           = Gauge("fusion_heat_nbi_efficiency_percent",   "NBI efficiency percent")
ecrh_power               = Gauge("fusion_heat_ecrh_power_MW",            "ECRH power MW")
ecrh_efficiency          = Gauge("fusion_heat_ecrh_efficiency_percent",  "ECRH efficiency percent")

# ── Vacuum ─────────────────────────────────────────────────────────────────────
vessel_pressure          = Gauge("fusion_vacuum_vessel_pressure_Pa",     "Vessel vacuum pressure Pascal")
leak_rate                = Gauge("fusion_vacuum_leak_rate_Pa_m3_per_s",  "Vacuum leak rate Pa·m³/s")

# ── First Wall / Divertor ──────────────────────────────────────────────────────
heatflux_inner           = Gauge("fusion_divertor_heatflux_inner_MW_m2", "Inner divertor heat flux MW/m²")
heatflux_outer           = Gauge("fusion_divertor_heatflux_outer_MW_m2", "Outer divertor heat flux MW/m²")
heatflux_wall            = Gauge("fusion_divertor_heatflux_wall_MW_m2",  "First wall peak heat flux MW/m²")
temp_inner_div           = Gauge("fusion_divertor_temp_inner_C",         "Inner divertor temperature °C")
temp_outer_div           = Gauge("fusion_divertor_temp_outer_C",         "Outer divertor temperature °C")
temp_first_wall          = Gauge("fusion_divertor_temp_wall_C",          "First wall average temperature °C")
erosion_rate             = Gauge("fusion_divertor_erosion_nm_per_s",     "Divertor tile erosion nm/s")

# ── Cooling ────────────────────────────────────────────────────────────────────
coolant_inlet_temp       = Gauge("fusion_cooling_inlet_temp_C",          "Primary coolant inlet temp °C")
coolant_outlet_temp      = Gauge("fusion_cooling_outlet_temp_C",         "Primary coolant outlet temp °C")
coolant_flow             = Gauge("fusion_cooling_flow_kg_per_s",         "Primary coolant flow kg/s")
coolant_pressure         = Gauge("fusion_cooling_pressure_MPa",          "Primary coolant pressure MPa")
cryo_temp                = Gauge("fusion_cryo_helium_temp_K",            "Cryogenic helium temperature K")

# ── Tritium ────────────────────────────────────────────────────────────────────
tritium_inventory        = Gauge("fusion_tritium_inventory_grams",       "Total tritium inventory grams")
tritium_burn_rate        = Gauge("fusion_tritium_burn_rate_mg_per_s",    "Tritium burn rate mg/s")
tritium_breeding_ratio   = Gauge("fusion_tritium_breeding_ratio",        "Tritium breeding ratio TBR")
tritium_airborne         = Gauge("fusion_tritium_airborne_Bq_per_m3",    "Airborne tritium Bq/m³")

# ── Power ──────────────────────────────────────────────────────────────────────
gross_thermal_power      = Gauge("fusion_power_gross_thermal_MW",        "Gross thermal power MW")
net_electrical_output    = Gauge("fusion_power_net_electrical_MW",       "Net electrical output MW")
recirculating_power      = Gauge("fusion_power_recirculating_MW",        "Recirculating power MW")
plant_efficiency         = Gauge("fusion_power_plant_efficiency_percent","Plant efficiency percent")

# ── Radiation ──────────────────────────────────────────────────────────────────
neutron_flux             = Gauge("fusion_rad_neutron_flux_per_cm2_s",    "Neutron flux per cm²/s")
neutron_wall_loading     = Gauge("fusion_rad_neutron_wall_loading_MW_m2","Neutron wall loading MW/m²")
gamma_control_room       = Gauge("fusion_rad_gamma_control_room_mSv_hr", "Gamma dose rate – control room mSv/hr")
gamma_hall               = Gauge("fusion_rad_gamma_hall_mSv_hr",         "Gamma dose rate – reactor hall mSv/hr")

# ── Diagnostics ───────────────────────────────────────────────────────────────
total_radiated_power     = Gauge("fusion_diag_total_radiated_power_MW",  "Total radiated power MW (bolometry)")
ion_temperature          = Gauge("fusion_diag_ion_temperature_keV",      "Ion temperature keV (CXRS)")
fusion_rate              = Gauge("fusion_diag_measured_fusion_rate_per_s","Measured fusion rate per second")

# ── Performance ────────────────────────────────────────────────────────────────
availability_30d         = Gauge("fusion_perf_availability_30d_percent", "30-day plant availability percent")
mean_time_between_disr   = Gauge("fusion_perf_MTBD_hours",               "Mean time between disruptions hours")
alarms_active            = Gauge("fusion_alarms_active_total",           "Total active alarms")
alarms_warnings_24h      = Gauge("fusion_alarms_warnings_24h",           "Warnings in last 24 hours")


def jitter(base: float, pct: float = 0.02) -> float:
    """Apply small random jitter ±pct% to a base value."""
    return base * (1 + random.uniform(-pct, pct))


def slow_wave(base: float, amplitude: float, period_s: float, t: float) -> float:
    """Sinusoidal variation for slow-moving process values."""
    return base + amplitude * math.sin(2 * math.pi * t / period_s)


def collect_and_publish():
    t = time.time()

    # ── Plasma ─────────────────────────────────────────────────────────────────
    temp = slow_wave(15.4, 0.6, 300, t)
    plasma_temp_kev.set(round(jitter(temp, 0.01), 3))
    plasma_temp_K.set(round(temp * 11604525.0, 0))
    plasma_density.set(jitter(1.2e20, 0.03))
    plasma_pressure.set(jitter(3.1e5, 0.02))
    plasma_confinement.set(jitter(1.2, 0.02))
    plasma_beta.set(jitter(0.047, 0.03))
    q = slow_wave(8.41, 0.5, 400, t)
    plasma_q_factor.set(round(jitter(q, 0.01), 3))
    fp = slow_wave(420.5, 15, 300, t)
    fusion_power.set(round(jitter(fp, 0.01), 2))
    hp = jitter(50.0, 0.01)
    heating_power.set(round(hp, 2))
    plasma_gain_Q.set(round(fp / hp, 3))
    deuterium_pct.set(jitter(50.0, 0.005))
    tritium_pct.set(jitter(50.0, 0.005))
    impurity_carbon.set(jitter(0.4, 0.05))
    impurity_oxygen.set(jitter(0.2, 0.05))
    impurity_tungsten.set(jitter(0.01, 0.05))
    helium_ash_pct.set(jitter(2.1, 0.04))

    # ── Magnetic ───────────────────────────────────────────────────────────────
    toroidal_field.set(jitter(5.3, 0.005))
    poloidal_field.set(jitter(0.8, 0.01))
    plasma_current.set(jitter(15.0, 0.005))
    disruption_risk.set(max(0, slow_wave(3.2, 2.0, 600, t) + random.gauss(0, 0.3)))
    elm_frequency.set(max(0, jitter(12.5, 0.1)))

    # ── Heating ────────────────────────────────────────────────────────────────
    nbi_power.set(jitter(20.0, 0.02))
    nbi_efficiency.set(jitter(82.3, 0.01))
    ecrh_power.set(jitter(20.0, 0.02))
    ecrh_efficiency.set(jitter(90.1, 0.005))

    # ── Vacuum ─────────────────────────────────────────────────────────────────
    vessel_pressure.set(jitter(1.5e-6, 0.05))
    leak_rate.set(jitter(2.1e-9, 0.05))

    # ── Divertor ───────────────────────────────────────────────────────────────
    heatflux_inner.set(jitter(8.4, 0.03))
    heatflux_outer.set(jitter(11.2, 0.03))
    heatflux_wall.set(jitter(1.8, 0.03))
    temp_inner_div.set(jitter(842, 0.02))
    temp_outer_div.set(jitter(1104, 0.02))
    temp_first_wall.set(jitter(320, 0.02))
    erosion_rate.set(jitter(0.003, 0.05))

    # ── Cooling ────────────────────────────────────────────────────────────────
    coolant_inlet_temp.set(jitter(70, 0.01))
    coolant_outlet_temp.set(jitter(150, 0.01))
    coolant_flow.set(jitter(1200, 0.02))
    coolant_pressure.set(jitter(1.5, 0.01))
    cryo_temp.set(jitter(4.5, 0.02))

    # ── Tritium ────────────────────────────────────────────────────────────────
    tritium_inventory.set(jitter(410.5, 0.005))
    tritium_burn_rate.set(jitter(0.056, 0.03))
    tritium_breeding_ratio.set(jitter(1.12, 0.02))
    tritium_airborne.set(jitter(12.5, 0.1))

    # ── Power ──────────────────────────────────────────────────────────────────
    gtp = jitter(420.5, 0.02)
    gross_thermal_power.set(round(gtp, 2))
    net_electrical_output.set(round(jitter(168.2, 0.02), 2))
    recirculating_power.set(jitter(85.0, 0.02))
    plant_efficiency.set(jitter(33.2, 0.01))

    # ── Radiation ──────────────────────────────────────────────────────────────
    neutron_flux.set(jitter(3.6e14, 0.02))
    neutron_wall_loading.set(jitter(0.78, 0.02))
    gamma_control_room.set(jitter(0.001, 0.05))
    gamma_hall.set(jitter(0.04, 0.05))

    # ── Diagnostics ────────────────────────────────────────────────────────────
    total_radiated_power.set(jitter(38.6, 0.03))
    ion_temperature.set(jitter(14.9, 0.02))
    fusion_rate.set(jitter(1.49e20, 0.02))

    # ── Performance ────────────────────────────────────────────────────────────
    availability_30d.set(91.4)
    mean_time_between_disr.set(jitter(128.4, 0.005))
    alarms_active.set(0)
    alarms_warnings_24h.set(1)


if __name__ == "__main__":
    print("Starting Fusion Reactor Prometheus Exporter on :8000 …")
    start_http_server(8000)
    while True:
        collect_and_publish()
        time.sleep(5)   # scrape-friendly 5-second refresh