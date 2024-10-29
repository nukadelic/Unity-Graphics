using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public class SetSDF : MonoBehaviour
{
    public GameObject AO_Box;
    // Start is called before the first frame update
    void Start()
    {
    }

    // Update is called once per frame
    void Update()
    {
        AO_Box.GetComponent<Renderer>().sharedMaterial.SetVector("_Position", transform.position);
        AO_Box.GetComponent<Renderer>().sharedMaterial.SetFloat("_Raduis", transform.localScale.x / 2);
    }
}
